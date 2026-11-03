#!/usr/bin/env bash
# DGX B300 5-stage gpu-burn logger v1.0
set -uo pipefail
STAGE="${1:-}"
DURATION="${2:-}"
INTERVAL=5
BURN="${GPU_BURN_PATH:-$HOME/gpu-burn/gpu_burn}"
ROOT="${GPU_TEST_ROOT:-$HOME/DGX_B300_GPU_Burn_5Stage}"
case "$STAGE" in
 baseline) GPUS=""; DEFAULT=1800; EXPECTED=0 ;;
 2gpu) GPUS="0,1"; DEFAULT=1800; EXPECTED=2 ;;
 4gpu) GPUS="0,1,2,3"; DEFAULT=1800; EXPECTED=4 ;;
 6gpu) GPUS="0,1,2,3,4,5"; DEFAULT=1800; EXPECTED=6 ;;
 8gpu) GPUS="0,1,2,3,4,5,6,7"; DEFAULT=3600; EXPECTED=8 ;;
 *) echo "用法: $0 {baseline|2gpu|4gpu|6gpu|8gpu} [seconds]"; exit 2 ;;
esac
DURATION="${DURATION:-$DEFAULT}"
if ! [[ "$DURATION" =~ ^[1-9][0-9]*$ ]]; then echo 'seconds 必須為正整數'; exit 2; fi
if ! command -v nvidia-smi >/dev/null 2>&1; then echo '找不到 nvidia-smi'; exit 1; fi
if [[ "$STAGE" != baseline && ! -x "$BURN" ]]; then echo "找不到 $BURN"; exit 1; fi
OUT="$ROOT/${STAGE}_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"
{
  echo "Stage=$STAGE"; echo "Duration_seconds=$DURATION";
  echo "Selected_GPU_Indices=$GPUS"; echo "Expected_GPU_Count=$EXPECTED";
  echo "GPU_Burn_Memory=50%"; echo "Monitor_Interval_seconds=$INTERVAL";
  echo "Start=$(date -Is)"; echo "Host=$(hostname)";
  echo "GPU_Burn_Binary=$BURN"
} | tee "$OUT/Test_Metadata.txt"
nvidia-smi -L > "$OUT/GPU_List.log" 2>&1
nvidia-smi -q -d ECC,ROW_REMAPPER > "$OUT/GPU_Health_Before.log" 2>&1
nvidia-smi > "$OUT/NVIDIA_SMI_Before.log" 2>&1
# 重要：即使只燒部分 GPU，CSV 仍監控全部 GPU。
nvidia-smi --query-gpu=timestamp,index,uuid,name,temperature.gpu,power.draw,utilization.gpu,utilization.memory,clocks.sm,memory.used,memory.total --format=csv --loop-ms=$((INTERVAL*1000)) > "$OUT/GPU_Monitor.csv" 2> "$OUT/Monitor_Error.log" &
MONPID=$!
cleanup() { kill "$MONPID" 2>/dev/null || true; wait "$MONPID" 2>/dev/null || true; }
trap cleanup EXIT
sleep 2
if ! kill -0 "$MONPID" 2>/dev/null; then echo '監控程序啟動失敗'; exit 1; fi
RC=0
if [[ "$STAGE" == baseline ]]; then
  echo 'Baseline：不啟動 gpu-burn，僅記錄所有 GPU 的待機狀態' | tee "$OUT/GPU_Burn.log"
  sleep "$DURATION" || RC=$?
else
  echo "啟動 gpu-burn: physical selection=$GPUS duration=$DURATION" | tee "$OUT/GPU_Burn.log"
  ( cd "$(dirname "$BURN")" && CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES="$GPUS" "$BURN" -m 50% "$DURATION" ) 2>&1 | tee -a "$OUT/GPU_Burn.log"
  RC=${PIPESTATUS[0]}
fi
cleanup
trap - EXIT
nvidia-smi -q -d ECC,ROW_REMAPPER > "$OUT/GPU_Health_After.log" 2>&1
nvidia-smi > "$OUT/NVIDIA_SMI_After.log" 2>&1
printf '%s\n' "$RC" > "$OUT/Exit_Code.txt"
printf 'End=%s\n' "$(date -Is)" >> "$OUT/Test_Metadata.txt"
echo "Exit Code: $RC"
echo "Result folder: $OUT"
echo '請檢查 GPU_Burn.log 實際 OK 數與 ECC/Row Remapper，Exit Code 0 並非單獨足夠的驗收依據。'
exit "$RC"
