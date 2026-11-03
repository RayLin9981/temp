#!/usr/bin/env bash
# DGX B300 GPU-Burn five-stage GPU + BMC acquisition (v1.1)
# Run one stage at a time. Requires gpu_burn, nvidia-smi, ipmitool and sudo privilege.
set -uo pipefail
STAGE="${1:-}"
DURATION="${2:-}"
GPU_INTERVAL=5
BMC_INTERVAL=10
BURN="${GPU_BURN_PATH:-$HOME/gpu-burn/gpu_burn}"
ROOT="${GPU_TEST_ROOT:-$HOME/DGX_B300_GPU_Burn_5Stage}"
case "$STAGE" in
  baseline) IDX=""; DEFAULT=1800; EXPECTED=0 ;;
  2gpu) IDX="0,1"; DEFAULT=2700; EXPECTED=2 ;;
  4gpu) IDX="0,1,2,3"; DEFAULT=2700; EXPECTED=4 ;;
  6gpu) IDX="0,1,2,3,4,5"; DEFAULT=2700; EXPECTED=6 ;;
  8gpu) IDX="0,1,2,3,4,5,6,7"; DEFAULT=5400; EXPECTED=8 ;;
  *) echo "Usage: $0 {baseline|2gpu|4gpu|6gpu|8gpu} [seconds]"; exit 2 ;;
esac
DURATION="${DURATION:-$DEFAULT}"
[[ "$DURATION" =~ ^[1-9][0-9]*$ ]] || { echo 'Duration must be positive integer seconds'; exit 2; }
for app in nvidia-smi ipmitool awk; do command -v "$app" >/dev/null || { echo "Missing $app"; exit 2; }; done
[[ "$STAGE" == baseline || -x "$BURN" ]] || { echo "Missing executable: $BURN"; exit 2; }
# Resolve OS-side nvidia-smi indices to stable GPU UUIDs; CUDA ordering can differ.
GPU_MAP="$(nvidia-smi --query-gpu=index,uuid --format=csv,noheader,nounits)" || exit 1
GPU_COUNT="$(printf '%s\n' "$GPU_MAP" | grep -c '^' || true)"
[[ "$GPU_COUNT" -eq 8 ]] || { echo "Expected 8 GPUs; found $GPU_COUNT. Aborting."; exit 1; }
UUIDS=""
if [[ -n "$IDX" ]]; then
  IFS=',' read -r -a selected <<< "$IDX"
  for idx in "${selected[@]}"; do
    uuid="$(printf '%s\n' "$GPU_MAP" | awk -F, -v idx="$idx" '{gsub(/ /,"",$1);gsub(/ /,"",$2);if($1==idx){print $2;exit}}')"
    [[ "$uuid" == GPU-* ]] || { echo "Cannot resolve GPU index $idx to UUID"; exit 1; }
    UUIDS="${UUIDS:+$UUIDS,}$uuid"
  done
fi
# sudo -v ensures the background monitor never waits for a password prompt.
sudo -v || exit 1
if ! sudo -n ipmitool sensor list >/dev/null; then echo 'Cannot query BMC via sudo ipmitool'; exit 1; fi
OUT="$ROOT/${STAGE}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
{
  printf 'Stage=%s\nStart=%s\nHost=%s\nDuration_seconds=%s\nSelected_nvidia_smi_indices=%s\nSelected_GPU_UUIDs=%s\nExpected_GPU_Count=%s\nGPU_Burn_Memory=50%%\nGPU_Sample_Interval_seconds=%s\nBMC_Minimum_Pause_seconds=%s\nGPU_Burn_Binary=%s\n' \
    "$STAGE" "$(date -Is)" "$(hostname)" "$DURATION" "${IDX:-none}" "${UUIDS:-none}" "$EXPECTED" "$GPU_INTERVAL" "$BMC_INTERVAL" "$BURN"
  printf '\nGPU mapping:\n%s\n' "$GPU_MAP"
} | tee "$OUT/Test_Metadata.txt"
nvidia-smi -L > "$OUT/GPU_List.log" 2>&1
nvidia-smi -q -d ECC,ROW_REMAPPER > "$OUT/GPU_Health_Before.log" 2>&1
nvidia-smi > "$OUT/NVIDIA_SMI_Before.log" 2>&1
sudo -n ipmitool sdr elist all > "$OUT/BMC_Sensors_Before.log" 2>&1
# All 8 GPUs are monitored regardless of which GPUs are stressed.
nvidia-smi --query-gpu=timestamp,index,uuid,name,temperature.gpu,power.draw,utilization.gpu,utilization.memory,clocks.sm,memory.used,memory.total \
  --format=csv --loop-ms=$((GPU_INTERVAL*1000)) \
  > "$OUT/GPU_Monitor.csv" 2> "$OUT/GPU_Monitor_Error.log" &
GPU_MON_PID=$!
# Long-format BMC CSV: easily pivoted into time series by sensor name.
printf 'timestamp,sensor,value,unit,status\n' > "$OUT/BMC_Monitor.csv"
(
  while true; do
    ts="$(date '+%Y-%m-%dT%H:%M:%S%z')"
    raw="$(sudo -n ipmitool sensor list 2>> "$OUT/BMC_Monitor_Error.log")"
    rc=$?
    if [[ $rc -ne 0 ]]; then
      echo "$ts,IPMI_QUERY_FAILED,$rc,,error" >> "$OUT/BMC_Monitor.csv"
    else
      printf '%s\n' "$raw" | awk -F'|' -v ts="$ts" '
        function trim(x){gsub(/^[ \t]+|[ \t]+$/, "", x);return x}
        {
          n=trim($1); v=trim($2); u=trim($3); s=trim($4)
          if(n ~ /^(PWR_SYSTEM|TEMP_MB_INLET|TEMP_MB_OUTLET|TEMP_AMBIENT|TEMP_GB1_INLET1|TEMP_GB1_INLET2|PWR_GB1_TOT_HSC|SPD_FAN_[1-4]_[1-5]_[FR])$/) {
            if(v=="na" || s!="ok") v=""
            print ts "," n "," v "," u "," s
          }
        }' >> "$OUT/BMC_Monitor.csv"
    fi
    sleep "$BMC_INTERVAL"
  done
) &
BMC_MON_PID=$!
cleanup() {
  kill "$GPU_MON_PID" "$BMC_MON_PID" 2>/dev/null || true
  wait "$GPU_MON_PID" "$BMC_MON_PID" 2>/dev/null || true
}
trap cleanup EXIT
sleep 2
if ! kill -0 "$GPU_MON_PID" 2>/dev/null || ! kill -0 "$BMC_MON_PID" 2>/dev/null; then
  echo 'A monitor stopped unexpectedly'; exit 1
fi
RC=0
if [[ "$STAGE" == baseline ]]; then
  echo 'Baseline: no gpu-burn started' | tee "$OUT/GPU_Burn.log"
  sleep "$DURATION" || RC=$?
else
  echo "GPU-Burn selected OS GPU indices=$IDX; UUIDs=$UUIDS; duration=$DURATION" | tee "$OUT/GPU_Burn.log"
  ( cd "$(dirname "$BURN")" && CUDA_VISIBLE_DEVICES="$UUIDS" "$BURN" -m 50% "$DURATION" ) 2>&1 | tee -a "$OUT/GPU_Burn.log"
  RC=${PIPESTATUS[0]}
fi
cleanup
trap - EXIT
nvidia-smi -q -d ECC,ROW_REMAPPER > "$OUT/GPU_Health_After.log" 2>&1
nvidia-smi > "$OUT/NVIDIA_SMI_After.log" 2>&1
sudo -n ipmitool sdr elist all > "$OUT/BMC_Sensors_After.log" 2>&1
printf '%s\n' "$RC" > "$OUT/Exit_Code.txt"
printf 'End=%s\n' "$(date -Is)" >> "$OUT/Test_Metadata.txt"
count="$(grep -Ec '^[[:space:]]*GPU[[:space:]]+[0-9]+:[[:space:]]+OK([[:space:]]|$)' "$OUT/GPU_Burn.log" || true)"
reported="$(sed -n -E 's/^Tested ([0-9]+) GPUs:.*/\1/p' "$OUT/GPU_Burn.log" | tail -1)"
[[ -n "$reported" ]] || reported=unavailable
summary='REVIEW'
if [[ "$STAGE" == baseline && $RC -eq 0 ]]; then
  summary='BASELINE_CAPTURED_CHECK_IDLE'
elif [[ "$RC" -eq 0 && "$count" -eq "$EXPECTED" && "$reported" == "$EXPECTED" ]]; then
  summary='GPU_BURN_OK_REVIEW_HEALTH_AND_TELEMETRY'
fi
{
  echo "Stage=$STAGE"
  echo "GPU_Burn_Exit_Code=$RC"
  echo "GPUs_Expected=$EXPECTED"
  echo "GPUs_Reported=$reported"
  echo "GPU_OK_Lines=$count"
  echo "Preliminary_Status=$summary"
  echo 'Important: check full GPU-Burn output, ECC, row remapper, throttling, BMC and GPU telemetry before acceptance.'
} | tee "$OUT/Preliminary_Result.txt"
echo "Result folder: $OUT"
exit "$RC"
