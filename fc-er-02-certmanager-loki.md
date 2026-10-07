# 既有叢集 — Phase 2：規格 4（cert-manager）＋ 規格 6（Loki / Alloy / Dashboard）

> 院方叢集為 **K8s v1.25.6**。版本選擇以「支援 1.25」為前提：
> - cert-manager：最新且支援 1.25 的是 **v1.15.x**（支援 1.25～1.32，官方已 EOL；目前有支援的 v1.20 / v1.21 要求 K8s ≥ 1.32）
> - Loki / Alloy / Grafana：chart 未限制 kubeVersion
>
> 所有元件都排到 **x86（amd64）一般節點**，避開 ac922（ppc64le）、DGX GPU 節點與 master。Alloy 例外：它要跑在每個 amd64 節點（含 DGX）收 log。

## 0. 變數

```bash
cd ~/fc-er
source ~/fc-er/phase1-env.sh            # 沿用 NODE_IP

cat <<'EOF' > ~/fc-er/phase2-env.sh
# ===== Phase 2 變數 =====
export CERT_MANAGER_VERSION="v1.15.5"   # 支援 K8s 1.25 的最後一版
export CA_ISSUER="fc-er-ca-issuer"
export CERT_DEMO_NS="cert-demo"
export CERT_DEMO_NODEPORT="30445"

export MON_NS="fc-er-monitoring"
export LOKI_CHART_VERSION="7.3.0"
export GRAFANA_NODEPORT="30446"
# 既有 Prometheus 的叢集內網址（0.2 步查到後填入）
export PROM_URL="TODO"                  # 例 http://prometheus-k8s.monitoring.svc.cluster.local:9090
EOF
vi ~/fc-er/phase2-env.sh
source ~/fc-er/phase2-env.sh

[[ -f ~/fc-er/phase2-secrets.sh ]] || cat <<EOF > ~/fc-er/phase2-secrets.sh
export GRAFANA_ADMIN_PASSWORD="$(openssl rand -hex 12)"
EOF
chmod 600 ~/fc-er/phase2-secrets.sh && source ~/fc-er/phase2-secrets.sh
```

### 0.1 共用：只排到 amd64 一般節點的 affinity

```bash
cat <<'EOF' > ~/fc-er/affinity-amd64.yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - {key: kubernetes.io/arch, operator: In, values: [amd64]}
          - {key: node-role.kubernetes.io/gpu, operator: DoesNotExist}
          - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
EOF
```

### 0.2 檢查既有環境

```bash
# cert-manager 是否已存在（kubespray 有選項可裝 cert-manager）
kubectl get crd | grep cert-manager.io || echo "未安裝 cert-manager"
kubectl get pods -A | grep -i cert-manager

# 既有 Prometheus / Grafana / DCGM Exporter
kubectl get svc -A | grep -Ei "prometheus|grafana"
kubectl get pods -A -o wide | grep -i dcgm

# 確認 Prometheus 有 DCGM 指標（把 URL 換成上面查到的 Service）
kubectl run promtest --rm -it --restart=Never --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}' -- \
  curl -s "${PROM_URL}/api/v1/query?query=count(DCGM_FI_DEV_GPU_UTIL)"
# 回傳 "result":[{"value":[...,"<GPU 數量>"]}] 代表有 DCGM 指標；空陣列代表沒有收到

kubectl get sc        # Loki / Grafana 的 PVC 需要預設 StorageClass
```

> - 若 cert-manager **已經裝好**，跳過 4.1，直接從 4.2 開始（`kubectl get deploy -n cert-manager -o wide` 看版本）。
> - 若沒有 DCGM 指標，需要先處理 DCGM Exporter / ServiceMonitor，Dashboard 的 GPU 圖才會有資料。

---

## 4. TLS 憑證管理：cert-manager（規格 4）

### 4.1 安裝 cert-manager v1.15.5

```bash
helm repo add jetstack https://charts.jetstack.io --force-update

cat <<'EOF' > ~/fc-er/cert-manager-values.yaml
crds:
  enabled: true
nodeSelector: {kubernetes.io/arch: amd64}
webhook:
  nodeSelector: {kubernetes.io/arch: amd64}
cainjector:
  nodeSelector: {kubernetes.io/arch: amd64}
startupapicheck:
  nodeSelector: {kubernetes.io/arch: amd64}
EOF

helm upgrade --install cert-manager jetstack/cert-manager \
  -n cert-manager --create-namespace \
  --version ${CERT_MANAGER_VERSION} -f ~/fc-er/cert-manager-values.yaml --wait
kubectl -n cert-manager get pods -o wide
```

### 4.2 建立自簽 Root CA 與 CA ClusterIssuer

自簽 Issuer → 簽出 Root CA → 用這把 CA 當平台的 ClusterIssuer。

```bash
cat <<EOF > ~/fc-er/ca-issuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-bootstrap
spec:
  selfSigned: {}
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: fc-er-root-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: FC-ER Root CA
  subject:
    organizations: [FC]
  secretName: fc-er-root-ca
  duration: 87600h          # 10 年
  privateKey:
    algorithm: RSA
    size: 4096
  issuerRef:
    name: selfsigned-bootstrap
    kind: ClusterIssuer
---
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CA_ISSUER}
spec:
  ca:
    secretName: fc-er-root-ca
EOF
kubectl apply -f ~/fc-er/ca-issuer.yaml
kubectl get clusterissuer
kubectl -n cert-manager get certificate fc-er-root-ca

# 匯出 CA 公鑰，給 Mac / 瀏覽器信任用
kubectl -n cert-manager get secret fc-er-root-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > ~/fc-er/fc-er-root-ca.crt
openssl x509 -in ~/fc-er/fc-er-root-ca.crt -noout -subject -dates
```

### 4.3 截圖用範例：HTTPS 網站 + 自動續期

一個 nginx 網站，使用 cert-manager 簽發的憑證，經 NodePort 30445 對外。
憑證刻意設成 **有效 1 小時、剩 55 分鐘就續期**，所以大約每 5 分鐘會自動續期一次，方便截到「自動續期」的證據。

```bash
kubectl create ns ${CERT_DEMO_NS} --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF > ~/fc-er/cert-demo.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: cert-demo-tls
  namespace: ${CERT_DEMO_NS}
spec:
  secretName: cert-demo-tls
  duration: 1h              # 示範用：短效憑證
  renewBefore: 55m          # 剩 55 分鐘就續期 → 約每 5 分鐘續期一次
  commonName: cert-demo.fc-er.internal
  dnsNames:
    - cert-demo.fc-er.internal
  ipAddresses:
    - ${NODE_IP}
  privateKey:
    algorithm: RSA
    size: 2048
    rotationPolicy: Always
  issuerRef:
    name: ${CA_ISSUER}
    kind: ClusterIssuer
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: cert-demo-nginx
  namespace: ${CERT_DEMO_NS}
data:
  default.conf: |
    server {
      listen 8443 ssl;
      ssl_certificate     /etc/nginx/tls/tls.crt;
      ssl_certificate_key /etc/nginx/tls/tls.key;
      location / {
        default_type text/plain;
        return 200 "FC-ER cert-manager demo - TLS issued by FC-ER Root CA\n";
      }
    }
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cert-demo
  namespace: ${CERT_DEMO_NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: cert-demo}
  template:
    metadata:
      labels: {app: cert-demo}
    spec:
      affinity:
$(sed 's/^/        /' ~/fc-er/affinity-amd64.yaml)
      containers:
        - name: nginx
          image: nginx:1.27
          ports:
            - containerPort: 8443
          volumeMounts:
            - {name: tls, mountPath: /etc/nginx/tls, readOnly: true}
            - {name: conf, mountPath: /etc/nginx/conf.d}
      volumes:
        - name: tls
          secret: {secretName: cert-demo-tls}
        - name: conf
          configMap: {name: cert-demo-nginx}
---
apiVersion: v1
kind: Service
metadata:
  name: cert-demo
  namespace: ${CERT_DEMO_NS}
spec:
  type: NodePort
  selector: {app: cert-demo}
  ports:
    - port: 8443
      targetPort: 8443
      nodePort: ${CERT_DEMO_NODEPORT}
EOF
kubectl apply -f ~/fc-er/cert-demo.yaml
kubectl -n ${CERT_DEMO_NS} get certificate -w     # READY=True 後 Ctrl+C
kubectl -n ${CERT_DEMO_NS} rollout status deploy/cert-demo
```

> nginx 讀到的是 Pod 啟動當下的憑證檔。Secret 更新後，掛載的檔案會在 1 分鐘內同步，但 nginx 要 reload 才會用新憑證。示範時用 `kubectl -n cert-demo rollout restart deploy/cert-demo` 即可；正式服務請選會自動重載憑證的程式（例如 Keycloak 26 預設每小時重載）。

#### 📸 規格 4 截圖清單

```bash
# ① cert-manager 元件
kubectl -n cert-manager get pods -o wide

# ② Issuer 與憑證
kubectl get clusterissuer
kubectl get certificate -A

# ③ 憑證內容：簽發者是 FC-ER Root CA
kubectl -n ${CERT_DEMO_NS} get secret cert-demo-tls -o jsonpath='{.data.tls\.crt}' \
  | base64 -d | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

# ④ 用 CA 驗證 HTTPS 連線（Verify return code: 0 (ok)）
curl -v --cacert ~/fc-er/fc-er-root-ca.crt https://${NODE_IP}:${CERT_DEMO_NODEPORT}/ 2>&1 \
  | grep -E "subject:|issuer:|expire date|SSL certificate verify|FC-ER"

# ⑤ 自動續期：等 10 分鐘以上再看，Revision 會增加，Events 有 Issuing / Reused 紀錄
kubectl -n ${CERT_DEMO_NS} describe certificate cert-demo-tls | grep -E "Revision|Not After|Renewal Time" -A0
kubectl -n ${CERT_DEMO_NS} get certificaterequest
kubectl -n ${CERT_DEMO_NS} get events --sort-by=.lastTimestamp | grep -i cert
```

⑥ 瀏覽器：Mac 先信任 CA（`sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain fc-er-root-ca.crt`），開 `https://<NODE_IP>:30445`，點網址列鎖頭 → 憑證資訊（簽發者 FC-ER Root CA、到期時間約 1 小時後）。

截完圖可以刪掉：`kubectl delete ns ${CERT_DEMO_NS}`

### 4.4（建議）Keycloak 改用 cert-manager 簽發

Phase 1 的 Keycloak 用 openssl 自簽。改由 cert-manager 管理同一個 Secret（`keycloak-tls`），Keycloak 26 會自動重載新憑證，可當作「平台服務憑證由 cert-manager 簽發」的正式案例。

```bash
cat <<EOF > ~/fc-er/keycloak-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: ${KC_NS}
spec:
  secretName: keycloak-tls
  duration: 2160h           # 90 天
  renewBefore: 720h         # 到期前 30 天續期
  commonName: ${KC_HOST}
  dnsNames: [keycloak.fc-er.internal]
  ipAddresses: [${NODE_IP}]
  issuerRef:
    name: ${CA_ISSUER}
    kind: ClusterIssuer
EOF
kubectl -n ${KC_NS} delete secret keycloak-tls     # 刪掉 openssl 版本，讓 cert-manager 重建
kubectl apply -f ~/fc-er/keycloak-cert.yaml
kubectl -n ${KC_NS} get certificate
kubectl -n ${KC_NS} rollout restart deploy/keycloak
```

---

## 6. 監控：Loki + Alloy + Grafana Dashboard（規格 6）

架構：

```
各節點 Pod log ──Alloy(DaemonSet)──▶ Loki ─┐
                                            ├──▶ Grafana（NodePort 30446）
既有 Prometheus（含 DCGM 指標）──────────────┘     └ Dashboard：GPU 指標 + Logs 同一頁
```

> 不動院方既有的 Prometheus / Grafana，另外起一個 Grafana 把兩個資料源接在一起。若院方要用既有 Grafana，只要加 Loki 資料源並匯入 6.4 的 Dashboard JSON 即可。

```bash
kubectl create ns ${MON_NS} --dry-run=client -o yaml | kubectl apply -f -
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### 6.1 Loki（Monolithic，檔案系統儲存）

```bash
{
cat <<'EOF'
deploymentMode: Monolithic
loki:
  auth_enabled: false
  commonConfig:
    replication_factor: 1
  storage:
    type: filesystem
  schemaConfig:
    configs:
      - from: "2024-04-01"
        store: tsdb
        object_store: filesystem
        schema: v13
        index:
          prefix: loki_index_
          period: 24h
  limits_config:
    retention_period: 336h        # 保留 14 天
    allow_structured_metadata: true
    volume_enabled: true
  compactor:
    retention_enabled: true
    delete_request_store: filesystem
singleBinary:
  replicas: 1
  persistence:
    enabled: true
    size: 100Gi
  affinity:
EOF
sed 's/^/    /' ~/fc-er/affinity-amd64.yaml
cat <<'EOF'
gateway:
  affinity:
EOF
sed 's/^/    /' ~/fc-er/affinity-amd64.yaml
cat <<'EOF'
minio: {enabled: false}
chunksCache: {enabled: false}
resultsCache: {enabled: false}
lokiCanary: {enabled: false}
test: {enabled: false}
backend: {replicas: 0}
read: {replicas: 0}
write: {replicas: 0}
ingester: {replicas: 0}
querier: {replicas: 0}
queryFrontend: {replicas: 0}
queryScheduler: {replicas: 0}
distributor: {replicas: 0}
compactor: {replicas: 0}
indexGateway: {replicas: 0}
bloomPlanner: {replicas: 0}
bloomBuilder: {replicas: 0}
bloomGateway: {replicas: 0}
EOF
} > ~/fc-er/loki-values.yaml

helm upgrade --install loki grafana-community/loki -n ${MON_NS} \
  --version ${LOKI_CHART_VERSION} -f ~/fc-er/loki-values.yaml --wait --timeout 10m
kubectl -n ${MON_NS} get pods,svc,pvc -o wide | grep -i loki    # 確認有 loki-gateway Service
```

> 若 helm 回報欄位錯誤，用 `helm show values grafana-community/loki --version ${LOKI_CHART_VERSION}` 對照（chart 7.x 改版較大）。

### 6.2 Alloy（每個 amd64 節點收集 Pod log → Loki）

```bash
cat <<EOF > ~/fc-er/alloy-values.yaml
controller:
  type: daemonset
  nodeSelector:
    kubernetes.io/arch: amd64     # ac922（ppc64le）不收；含 DGX
  tolerations:
    - operator: Exists            # DGX / master 若有 taint 也要能排上去
alloy:
  configMap:
    content: |-
      // 只收「本節點」上的 Pod（chart 會把 HOSTNAME 設為節點名稱）
      discovery.kubernetes "pod" {
        role = "pod"
        selectors {
          role  = "pod"
          field = "spec.nodeName=" + coalesce(sys.env("HOSTNAME"), constants.hostname)
        }
      }

      discovery.relabel "pod_logs" {
        targets = discovery.kubernetes.pod.targets
        rule {
          source_labels = ["__meta_kubernetes_namespace"]
          target_label  = "namespace"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_name"]
          target_label  = "pod"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_container_name"]
          target_label  = "container"
        }
        rule {
          source_labels = ["__meta_kubernetes_pod_node_name"]
          target_label  = "node"
        }
      }

      loki.source.kubernetes "pod_logs" {
        targets    = discovery.relabel.pod_logs.output
        forward_to = [loki.write.default.receiver]
      }

      loki.write "default" {
        endpoint {
          url = "http://loki-gateway.${MON_NS}.svc.cluster.local/loki/api/v1/push"
        }
        external_labels = { cluster = "vghtpe" }
      }
EOF

helm upgrade --install alloy grafana/alloy -n ${MON_NS} -f ~/fc-er/alloy-values.yaml --wait
kubectl -n ${MON_NS} get ds alloy
kubectl -n ${MON_NS} get pods -o wide -l app.kubernetes.io/name=alloy
# 確認 HOSTNAME 是節點名稱
kubectl -n ${MON_NS} exec ds/alloy -c alloy -- printenv HOSTNAME
```

> ac922 是 ppc64le，Alloy 是否提供 ppc64le image 我不確定，因此先排除。若院方需要收 ac922 的 log，再另外處理。

### 6.3 Grafana（NodePort 30446，接既有 Prometheus + Loki）

```bash
{
cat <<EOF
adminPassword: "${GRAFANA_ADMIN_PASSWORD}"
service:
  type: NodePort
  nodePort: ${GRAFANA_NODEPORT}
persistence:
  enabled: true
  size: 5Gi
affinity:
EOF
sed 's/^/  /' ~/fc-er/affinity-amd64.yaml
cat <<EOF
datasources:
  datasources.yaml:
    apiVersion: 1
    datasources:
      - name: Prometheus
        uid: prometheus
        type: prometheus
        access: proxy
        url: ${PROM_URL}
        isDefault: true
      - name: Loki
        uid: loki
        type: loki
        access: proxy
        url: http://loki-gateway.${MON_NS}.svc.cluster.local
# 自訂 Dashboard（6.4 的 ConfigMap）由 sidecar 載入
sidecar:
  dashboards:
    enabled: true
    label: grafana_dashboard
    folderAnnotation: grafana_folder
    provider:
      foldersFromFilesStructure: true
# 匯入 NVIDIA 官方 DCGM Exporter Dashboard（grafana.com ID 12239）
dashboardProviders:
  dashboardproviders.yaml:
    apiVersion: 1
    providers:
      - name: gpu
        orgId: 1
        folder: GPU
        type: file
        disableDeletion: false
        editable: true
        options:
          path: /var/lib/grafana/dashboards/gpu
dashboards:
  gpu:
    nvidia-dcgm-exporter:
      gnetId: 12239
      revision: 2
      datasource: Prometheus
EOF
} > ~/fc-er/grafana-values.yaml
chmod 600 ~/fc-er/grafana-values.yaml

helm upgrade --install grafana grafana-community/grafana -n ${MON_NS} \
  -f ~/fc-er/grafana-values.yaml --wait
kubectl -n ${MON_NS} get pods,svc -o wide | grep grafana
echo "Grafana: http://${NODE_IP}:${GRAFANA_NODEPORT}  帳號 admin  密碼 ${GRAFANA_ADMIN_PASSWORD}"
```

> DCGM Dashboard 會在 Grafana 啟動時從 grafana.com 下載（叢集要能連外）。下載失敗時，在 UI → Dashboards → New → Import 輸入 `12239` 手動匯入。

### 6.4 自訂 Dashboard：GPU 指標 + Logs 同一頁

上半部是 GPU 指標（使用率、顯存、功耗、溫度），下半部是 Log 量與 Log 內容。頂端可選節點、namespace，並輸入 log 關鍵字。

```bash
cat <<'EOF' > ~/fc-er/fc-er-gpu-logs.json
{
  "uid": "fc-er-gpu-logs",
  "title": "FC-ER GPU Metrics + Logs",
  "tags": ["fc-er", "gpu", "logs"],
  "schemaVersion": 39,
  "editable": true,
  "refresh": "30s",
  "time": {"from": "now-1h", "to": "now"},
  "templating": {
    "list": [
      {
        "name": "node", "label": "GPU 節點", "type": "query",
        "datasource": {"type": "prometheus", "uid": "prometheus"},
        "definition": "label_values(DCGM_FI_DEV_GPU_UTIL, Hostname)",
        "query": {"query": "label_values(DCGM_FI_DEV_GPU_UTIL, Hostname)", "refId": "node"},
        "includeAll": true, "multi": true, "allValue": ".*", "refresh": 2,
        "current": {"text": "All", "value": "$__all"}
      },
      {
        "name": "namespace", "label": "Namespace", "type": "query",
        "datasource": {"type": "loki", "uid": "loki"},
        "definition": "label_values(namespace)",
        "query": {"label": "namespace", "refId": "ns", "stream": "", "type": 1},
        "includeAll": true, "multi": true, "allValue": ".+", "refresh": 2,
        "current": {"text": "All", "value": "$__all"}
      },
      {
        "name": "search", "label": "Log 關鍵字", "type": "textbox",
        "query": "", "current": {"text": "", "value": ""}
      }
    ]
  },
  "panels": [
    {
      "id": 1, "type": "timeseries", "title": "GPU 使用率 (%)",
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 0},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "fieldConfig": {"defaults": {"unit": "percent", "min": 0, "max": 100}, "overrides": []},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
        "expr": "DCGM_FI_DEV_GPU_UTIL{Hostname=~\"$node\"}", "legendFormat": "{{Hostname}} GPU{{gpu}}"}]
    },
    {
      "id": 2, "type": "timeseries", "title": "GPU 顯存使用 (MiB)",
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 0},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "fieldConfig": {"defaults": {"unit": "decmbytes", "min": 0}, "overrides": []},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
        "expr": "DCGM_FI_DEV_FB_USED{Hostname=~\"$node\"}", "legendFormat": "{{Hostname}} GPU{{gpu}}"}]
    },
    {
      "id": 3, "type": "timeseries", "title": "功耗 (W)",
      "gridPos": {"h": 7, "w": 12, "x": 0, "y": 8},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "fieldConfig": {"defaults": {"unit": "watt", "min": 0}, "overrides": []},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
        "expr": "DCGM_FI_DEV_POWER_USAGE{Hostname=~\"$node\"}", "legendFormat": "{{Hostname}} GPU{{gpu}}"}]
    },
    {
      "id": 4, "type": "timeseries", "title": "溫度 (°C)",
      "gridPos": {"h": 7, "w": 12, "x": 12, "y": 8},
      "datasource": {"type": "prometheus", "uid": "prometheus"},
      "fieldConfig": {"defaults": {"unit": "celsius"}, "overrides": []},
      "targets": [{"refId": "A", "datasource": {"type": "prometheus", "uid": "prometheus"},
        "expr": "DCGM_FI_DEV_GPU_TEMP{Hostname=~\"$node\"}", "legendFormat": "{{Hostname}} GPU{{gpu}}"}]
    },
    {
      "id": 5, "type": "timeseries", "title": "Log 量（每分鐘，依 namespace）",
      "gridPos": {"h": 6, "w": 24, "x": 0, "y": 15},
      "datasource": {"type": "loki", "uid": "loki"},
      "fieldConfig": {"defaults": {"custom": {"drawStyle": "bars", "fillOpacity": 60}}, "overrides": []},
      "targets": [{"refId": "A", "datasource": {"type": "loki", "uid": "loki"},
        "expr": "sum by (namespace) (count_over_time({namespace=~\"$namespace\"} |~ \"$search\" [1m]))",
        "legendFormat": "{{namespace}}"}]
    },
    {
      "id": 6, "type": "logs", "title": "Logs",
      "gridPos": {"h": 14, "w": 24, "x": 0, "y": 21},
      "datasource": {"type": "loki", "uid": "loki"},
      "options": {"showTime": true, "wrapLogMessage": true, "sortOrder": "Descending",
        "enableLogDetails": true, "prettifyLogMessage": false},
      "targets": [{"refId": "A", "datasource": {"type": "loki", "uid": "loki"},
        "expr": "{namespace=~\"$namespace\"} |~ \"$search\""}]
    }
  ]
}
EOF
python3 -m json.tool ~/fc-er/fc-er-gpu-logs.json > /dev/null && echo "JSON OK"

kubectl -n ${MON_NS} create configmap fc-er-gpu-logs-dashboard \
  --from-file=fc-er-gpu-logs.json=$HOME/fc-er/fc-er-gpu-logs.json \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ${MON_NS} label configmap fc-er-gpu-logs-dashboard grafana_dashboard=1 --overwrite
kubectl -n ${MON_NS} annotate configmap fc-er-gpu-logs-dashboard grafana_folder=FC-ER --overwrite
```

> 院方 DCGM 指標的節點標籤若不是 `Hostname`（例如 `instance`、`kubernetes_node`），把 JSON 裡的 `Hostname` 全部換掉：`sed -i 's/Hostname/instance/g' ~/fc-er/fc-er-gpu-logs.json` 後重新建立 ConfigMap。先用 Grafana Explore 查 `DCGM_FI_DEV_GPU_UTIL` 看實際有哪些標籤。

### 6.5（選做）測試 Pod：讓 Log 與 GPU 指標對得起來

每 5 秒印一次 GPU 狀態到 log，Dashboard 上半部看到指標、下半部看到同一時間的 log。會佔用 1 張 GPU，**請先取得院方同意**，截完圖立即刪除。

```bash
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: Pod
metadata:
  name: gpu-log-demo
  namespace: fc-er-monitoring
spec:
  restartPolicy: Never
  activeDeadlineSeconds: 900          # 15 分鐘後自動結束
  tolerations:
    - operator: Exists
  containers:
    - name: smi
      image: nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04
      command: ["nvidia-smi", "--query-gpu=timestamp,name,utilization.gpu,memory.used,power.draw,temperature.gpu", "--format=csv", "-l", "5"]
      resources:
        limits:
          nvidia.com/gpu: 1
EOF
kubectl -n fc-er-monitoring get pod gpu-log-demo -o wide
kubectl -n fc-er-monitoring logs -f gpu-log-demo
# 截完圖：kubectl -n fc-er-monitoring delete pod gpu-log-demo
```

### 6.6 📸 規格 6 截圖清單

| # | 畫面 | 對應原文 |
|---|---|---|
| ① | `kubectl get pods -A -o wide \| grep -i -E "gpu-operator\|dcgm"` | 整合 NVIDIA GPU Operator |
| ② | `kubectl -n fc-er-monitoring get pods,svc -o wide`（Loki、Alloy、Grafana） | 監控平台 |
| ③ | Grafana → Connections → Data sources：Prometheus、Loki 都按 **Save & test** 成功 | 指標 + 日誌 |
| ④ | Grafana → Dashboards → GPU → **NVIDIA DCGM Exporter Dashboard** | GPU 專屬監控儀表板 |
| ⑤ | Grafana → Dashboards → FC-ER → **FC-ER GPU Metrics + Logs**（上 GPU 指標、下 logs） | 指標與日誌整合查詢 |
| ⑥ | 在 ⑤ 選 namespace `fc-er-monitoring`、關鍵字 `NVIDIA` → 只剩 gpu-log-demo 的 log | 整合查詢 |
| ⑦ | Grafana → Explore → Split：左 Prometheus `DCGM_FI_DEV_GPU_UTIL`、右 Loki `{namespace="fc-er-monitoring"}` | 整合查詢 |

---

## 常見問題

| 狀況 | 排查 |
|---|---|
| cert-manager webhook 逾時（`failed calling webhook`） | API server 連不到 webhook Pod。kubespray + Calico 一般沒問題；檢查 `kubectl -n cert-manager get pods -o wide` 是否在 amd64 節點、NetworkPolicy 是否擋住 |
| Certificate 一直 `READY=False` | `kubectl describe certificate`、`kubectl get certificaterequest,order -A`；CA ClusterIssuer 必須先 Ready |
| Grafana 的 Prometheus 資料源 test 失敗 | `PROM_URL` 錯誤；用 0.2 步的 curl 測試同一個 URL |
| Dashboard GPU 圖沒資料 | Prometheus 沒有 DCGM 指標，或節點標籤不是 `Hostname`（見 6.4 備註） |
| Logs 面板空白 | `kubectl -n fc-er-monitoring logs ds/alloy` 看是否推送失敗；確認 `loki-gateway` Service 名稱 |
| Alloy 在 DGX 沒起來 | DGX 有其他 taint 或 nodeSelector 不符，`kubectl describe pod` 看 Events |
