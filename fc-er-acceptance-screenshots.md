# 115TC059Q 驗收截圖手冊（規格二、第 2～7 項）

> 只列「驗收時要執行什麼、截什麼、應該看到什麼」，不含建置步驟（建置見 `fc-er-existing-cluster-install.md`）。
> 環境：院方既有叢集 K8s v1.25.6，所有服務以 NodePort 對外。

## 0. 驗收前準備

### 0.1 載入變數

```bash
source ~/fc-er/env.sh && source ~/fc-er/secrets.sh
echo "NODE_IP=${NODE_IP}"
```

### 0.2 截圖原則

- 每張終端截圖前先執行下列指令，讓畫面帶出**主機、時間、叢集**，證明是驗收當下在本叢集執行：
  ```bash
  echo "=== $(hostname) | $(date '+%F %T') | $(kubectl config current-context) ==="
  ```
- 瀏覽器截圖要包含**網址列**（看得到 IP:Port 與 HTTPS 鎖頭）。
- 檔名建議：`S<規格>-<序號>-<內容>.png`，例：`S5-03-harbor-push.png`。

### 0.3 Mac 端（瀏覽器截圖用）

```bash
# 信任 Root CA，HTTPS 頁面才會顯示正常的鎖頭（只需做一次）
scp root@k8sm01:~/fc-er/fc-er-root-ca.crt ~/fc-er-root-ca.crt
sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ~/fc-er-root-ca.crt
```

### 0.4 服務入口

| 服務 | 網址 | 帳號 |
|---|---|---|
| Keycloak | `https://<NODE_IP>:30443/admin` | `admin` / `KC_ADMIN_PASSWORD` |
| Harbor | `https://<NODE_IP>:30003` | `admin` / `HARBOR_ADMIN_PASSWORD`，或 OIDC |
| Grafana | `http://<NODE_IP>:30446` | `admin` / `GRAFANA_ADMIN_PASSWORD` |
| Headlamp | `http://<NODE_IP>:30444` | ServiceAccount token |
| cert-manager 範例站 | `https://<NODE_IP>:30445` | — |
| 負載平衡範例 | `http://<NODE_IP>:30447` | — |

```bash
# 列出所有密碼
cat ~/fc-er/secrets.sh
# Headlamp 登入 token
kubectl -n headlamp create token headlamp-admin --duration=8h
```

### 0.5 測試資源（若已刪除，先重新建立）

```bash
kubectl apply -f ~/fc-er/lb-demo.yaml       # 規格 2
kubectl apply -f ~/fc-er/cert-demo.yaml     # 規格 4
kubectl apply -f ~/fc-er/harbor-demo.yaml   # 規格 5
kubectl -n lb-demo rollout status deploy/lb-demo
kubectl -n cert-demo rollout status deploy/cert-demo
kubectl -n harbor-demo rollout status deploy/harbor-demo
```

---

## 規格 2：容器建置（多副本、負載平衡）

> 原文：建置 Kubernetes 容器管理平台，可於平台建立多副本之容器服務，確保服務連線可負載平衡分散流量處理。

| # | 截圖 | 執行 / 操作 | 預期結果 |
|---|---|---|---|
| S2-01 | 叢集節點 | `kubectl get nodes -o wide` | 所有節點 Ready、版本 v1.25.6 |
| S2-02 | 多副本 | `kubectl -n lb-demo get deploy,rs,pods -o wide` | READY 3/3，Pod 分散在不同節點 |
| S2-03 | Service 後端 | `kubectl -n lb-demo get svc,endpoints -o wide` | NodePort 30447，Endpoints 有 3 個 Pod IP |
| S2-04 | 叢集內負載平衡 | 見下方指令 ① | 3 個 Pod 都有分到流量 |
| S2-05 | 叢集外負載平衡 | 見下方指令 ② | 3 個 Pod 都有分到流量 |
| S2-06 | 故障不中斷 | 見下方指令 ③ | 無（或極少）FAILED，Pod 自動補回 |
| S2-07 | 擴充副本 | 見下方指令 ④ | 5 個 Endpoint，5 個 Pod 都有流量 |
| — | 證照 | 公司 KCSP 證明、工程師 CKA 證照影本 | 文件佐證，確認在有效期內 |

```bash
# ① 叢集內：經 ClusterIP 連 60 次
kubectl -n lb-demo run lbtest --rm -i --restart=Never --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}' -- \
  sh -c 'for i in $(seq 1 60); do curl -s http://lb-demo; done' | sort | uniq -c

# ② 叢集外：經 NodePort 連 60 次
for i in $(seq 1 60); do curl -s http://${NODE_IP}:30447/; done | sort | uniq -c

# ③ 持續連線中刪除一個 Pod
( for i in $(seq 1 40); do curl -s -m 2 http://${NODE_IP}:30447/ || echo "FAILED"; sleep 0.5; done ) > /tmp/lb-failover.log &
sleep 3; kubectl -n lb-demo delete pod $(kubectl -n lb-demo get pods -l app=lb-demo -o jsonpath='{.items[0].metadata.name}') --wait=false
wait; sort /tmp/lb-failover.log | uniq -c
kubectl -n lb-demo get pods -o wide

# ④ 擴充到 5 副本
kubectl -n lb-demo scale deploy/lb-demo --replicas=5 && kubectl -n lb-demo rollout status deploy/lb-demo
kubectl -n lb-demo get endpoints lb-demo
for i in $(seq 1 100); do curl -s http://${NODE_IP}:30447/; done | sort | uniq -c
kubectl -n lb-demo scale deploy/lb-demo --replicas=3     # 截完縮回
```

---

## 規格 3：帳號整合（帳號建立、DNS、AD、OIDC、單一登入）

> 原文：提供帳號整合系統，負責帳號建立、DNS 解析之維護，整合 AD 帳號系統與具備 OIDC 之平台串接，實現 K8S、Harbor 等平台單一登入功能。

| # | 截圖 | 執行 / 操作 | 預期結果 |
|---|---|---|---|
| S3-01 | Keycloak 元件 | `kubectl -n keycloak get pods,svc,pvc,certificate -o wide` | Running、NodePort 30443、憑證 READY |
| S3-02 | 帳號建立 | Keycloak → realm `fc-er` → **Users** | 看到 `eradmin01`、`eruser01` |
| S3-03 | 群組 | Keycloak → **Groups** → `harbor-admins` → Members | `eradmin01` 在群組內 |
| S3-04 | OIDC client | Keycloak → **Clients** → `harbor` → Settings | Redirect URI = `https://<NODE_IP>:30003/c/oidc/callback` |
| S3-05 | OIDC Discovery | 見下方指令 ① | 回傳 issuer 與各 endpoint |
| S3-06 | DNS 解析（叢集內） | 見下方指令 ② | 服務名稱可解析成 ClusterIP |
| S3-07 | Harbor SSO 設定 | Harbor → Administration → Configuration → **Authentication** | Auth Mode = OIDC；按 **Test OIDC Server** 成功 |
| S3-08 | Harbor SSO 登入頁 | 登出 Harbor → 登入頁 | 出現 **LOGIN VIA OIDC PROVIDER** |
| S3-09 | 跳轉 Keycloak | 按上一步按鈕 | 網址列為 `:30443/realms/fc-er/...` 的 Keycloak 登入頁 |
| S3-10 | 登入成功 | 輸入 `eradmin01` / `KC_TEST_PASSWORD` | 回到 Harbor，右上角為 `eradmin01`，可見 Administration |
| S3-11 | 自動建帳 | Harbor → Administration → **Users** | `eradmin01`、`eruser01` 由 OIDC 自動建立 |
| S3-12 | 一般使用者權限 | 登出，改用 `eruser01` 登入 | 沒有 Administration 選單 |
| S3-13 | AD 整合 | Keycloak → **User federation** → AD provider → Test connection / authentication | ⚠️ **尚未建置**（見文末缺口） |
| S3-14 | K8S 單一登入 | `kubectl auth whoami`（OIDC 使用者） | ⚠️ **尚未建置**（見文末缺口） |

```bash
# ① OIDC Discovery
curl -s --cacert ~/fc-er/keycloak-ca.crt ${KC_URL}/realms/fc-er/.well-known/openid-configuration \
  | jq '{issuer, authorization_endpoint, token_endpoint, userinfo_endpoint}'

# ② 叢集內 DNS 解析
kubectl -n kube-system get pods -l k8s-app=kube-dns -o wide
kubectl run dnstest --rm -i --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}' -- \
  sh -c 'for s in keycloak.keycloak harbor.harbor grafana.fc-er-monitoring lb-demo.lb-demo; do nslookup $s.svc.cluster.local | grep -A1 Name; done'
```

---

## 規格 4：TLS 憑證管理

> 原文：需建置 TLS 憑證管理系統，可負責全平台服務之 SSL/TLS 憑證簽發、部署。

| # | 截圖 | 執行 / 操作 | 預期結果 |
|---|---|---|---|
| S4-01 | 憑證管理系統 | `kubectl -n cert-manager get pods -o wide` | cert-manager、cainjector、webhook 皆 Running |
| S4-02 | 簽發者 | `kubectl get clusterissuer` | `fc-er-ca-issuer` READY=True |
| S4-03 | 全平台憑證 | `kubectl get certificate -A` | cert-demo、keycloak、harbor 憑證皆 READY=True |
| S4-04 | 憑證內容 | 見下方指令 ① | Issuer = FC-ER Root CA，SAN 含節點 IP |
| S4-05 | HTTPS 驗證 | 見下方指令 ② | `SSL certificate verify ok` |
| S4-06 | 自動續期 | 見下方指令 ③（範例憑證每 ~5 分鐘續期） | Revision 數字增加、有多筆 CertificateRequest |
| S4-07 | 部署（瀏覽器） | 開 `https://<NODE_IP>:30445` → 點鎖頭 → 憑證 | 簽發者 FC-ER Root CA，鎖頭正常 |
| S4-08 | 部署到平台服務 | 同上，開 Keycloak `:30443`、Harbor `:30003` 看憑證 | 簽發者皆為 FC-ER Root CA |

```bash
# ① 憑證內容
for ns_s in cert-demo/cert-demo-tls keycloak/keycloak-tls harbor/harbor-tls; do
  ns=${ns_s%/*}; s=${ns_s#*/}; echo "== ${ns}/${s}"
  kubectl -n $ns get secret $s -o jsonpath='{.data.tls\.crt}' | base64 -d \
    | openssl x509 -noout -subject -issuer -enddate -ext subjectAltName
done

# ② HTTPS 驗證（用 Root CA 驗證，不加 -k）
curl -sv --cacert ~/fc-er/fc-er-root-ca.crt https://${NODE_IP}:30445/ 2>&1 \
  | grep -E "subject:|issuer:|expire date|SSL certificate verify|FC-ER"

# ③ 自動續期（相隔 10 分鐘各截一次）
kubectl -n cert-demo describe certificate cert-demo-tls | grep -E "Revision|Not After|Renewal Time"
kubectl -n cert-demo get certificaterequest
```

---

## 規格 5：私有映像倉庫（Harbor）

> 原文：需負責容器映像檔私有倉庫建置，可存放容器映像檔並提供給容器平台使用。

| # | 截圖 | 執行 / 操作 | 預期結果 |
|---|---|---|---|
| S5-01 | Harbor 元件 | `kubectl -n harbor get pods,svc,pvc -o wide` | 全部 Running，`harbor` Service 為 NodePort 30003 |
| S5-02 | Harbor 健康 | 見下方指令 ① | `Pong`、版本 v2.15.x |
| S5-03 | 私有專案 | Harbor → Projects → `fc-er` | Access Level = **Private** |
| S5-04 | 推送映像 | 見下方指令 ② | push 成功，顯示 digest |
| S5-05 | 倉庫內容 | Harbor → `fc-er` → Repositories → `nginx` → `1.27` | 看到 tag、digest、推送時間 |
| S5-06 | 平台拉取 | 見下方指令 ③ | Pod Running，Events 有 `Successfully pulled image "<NODE_IP>:30003/fc-er/nginx:1.27"` |
| S5-07 | 拉取帳號 | Harbor → `fc-er` → Robot Accounts | `k8s-pull`，僅 pull 權限 |

```bash
# ① 健康檢查
curl -s --cacert ~/fc-er/fc-er-root-ca.crt ${HARBOR_URL}/api/v2.0/ping; echo
curl -s --cacert ~/fc-er/fc-er-root-ca.crt ${HARBOR_URL}/api/v2.0/systeminfo | jq '{harbor_version, external_url, auth_mode}'

# ② 推送（改個 tag 讓推送時間是驗收當下）
TAG=accept-$(date +%m%d%H%M)
nerdctl tag docker.io/library/nginx:1.27 ${HARBOR_ADDR}/fc-er/nginx:${TAG}
echo "${HARBOR_ADMIN_PASSWORD}" | nerdctl login ${HARBOR_ADDR} -u admin --password-stdin
nerdctl push ${HARBOR_ADDR}/fc-er/nginx:${TAG}

# ③ 平台從 Harbor 拉取
kubectl -n harbor-demo rollout restart deploy/harbor-demo && kubectl -n harbor-demo rollout status deploy/harbor-demo
kubectl -n harbor-demo get pods -o wide
kubectl -n harbor-demo get events --sort-by=.lastTimestamp | grep -E "Pulling|Pulled"
kubectl -n harbor-demo get deploy harbor-demo -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

---

## 規格 6：GPU Operator 與監控平台

> 原文：整合 NVIDIA GPU Operator，建立涵蓋「指標（Metrics）」與「日誌（Logs）」的監控平台，並提供 GPU 專屬監控儀表板，提供 GPU 指標、系統指標及日誌之整合查詢。

| # | 截圖 | 執行 / 操作 | 預期結果 |
|---|---|---|---|
| S6-01 | GPU Operator | `kubectl -n gpu-operator get pods -o wide` | 全部 Running / Completed |
| S6-02 | GPU 資源 | 見下方指令 ① | GPU 節點 allocatable `nvidia.com/gpu` 有數量 |
| S6-03 | 監控元件 | `kubectl -n fc-er-monitoring get pods,svc -o wide` | Loki、Alloy（每個 amd64 節點一個）、Grafana 皆 Running |
| S6-04 | 指標來源 | Grafana → Connections → Data sources → **Prometheus** → Save & test | 成功 |
| S6-05 | 日誌來源 | 同上 → **Loki** → Save & test | 成功 |
| S6-06 | GPU 專屬儀表板 | Grafana → Dashboards → GPU → **NVIDIA DCGM Exporter Dashboard** | 各 GPU 使用率、溫度、功耗、顯存曲線 |
| S6-07 | 整合儀表板 | Dashboards → FC-ER → **FC-ER GPU Metrics + Logs** | 上半 GPU 指標、下半 Logs |
| S6-08 | 日誌查詢 | 在 S6-07 選 namespace、輸入關鍵字 | Logs 面板只剩符合的紀錄 |
| S6-09 | 指標 + 日誌整合查詢 | Grafana → **Explore** → Split：左 Prometheus、右 Loki（見下方 ②） | 同一時間軸並排顯示 |
| S6-10 | 系統指標 | Explore（Prometheus）查 `100 - avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))*100` | 各節點 CPU 使用率 |

```bash
# ① GPU 資源
kubectl get nodes -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu' | grep -v "<none>"

# ② Explore 查詢語法
#   左（Prometheus）：DCGM_FI_DEV_GPU_UTIL
#   右（Loki）     ：{namespace="gpu-operator"}
```

> 若要讓 GPU 曲線與 log 同時有變化，可用建置手冊 4.5 的 `gpu-log-demo` Pod（會佔用 1 張 GPU，需先取得院方同意）。

---

## 規格 7：網頁管理介面（Headlamp）

> 原文：須提供 Rancher 或 Headlamp 網頁管理介面，可透過介面建立 K8S 資源，觀察平台系統資源使用量，降低操作門檻並提升叢集可視化程度。

| # | 截圖 | 執行 / 操作 | 預期結果 |
|---|---|---|---|
| S7-01 | Headlamp 元件 | `kubectl -n headlamp get pods,svc -o wide` | Running，NodePort 30444 |
| S7-02 | 叢集總覽 | 開 `http://<NODE_IP>:30444` → 用 token 登入 → Cluster | 節點、Pod、事件總覽 |
| S7-03 | 建立資源 | 右上 **Create** → 貼上下方 YAML → Apply | 建立成功提示 |
| S7-04 | 確認建立 | Workloads → Deployments → `headlamp-demo` | 2/2 Ready |
| S7-05 | 操作資源 | `headlamp-demo` → Scale 改成 3 | Pod 變成 3 個 |
| S7-06 | 資源用量（節點） | Nodes 頁 | 各節點 CPU / Memory 使用量 |
| S7-07 | 資源用量（Pod） | `headlamp-demo` 的 Pod 詳細頁 | CPU / Memory 圖表 |

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: headlamp-demo
  namespace: default
spec:
  replicas: 2
  selector:
    matchLabels: {app: headlamp-demo}
  template:
    metadata:
      labels: {app: headlamp-demo}
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - {key: kubernetes.io/arch, operator: In, values: [amd64]}
                  - {key: node-role.kubernetes.io/gpu, operator: DoesNotExist}
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests: {cpu: 50m, memory: 64Mi}
```

截完圖清除：`kubectl delete deploy headlamp-demo -n default`

---

## 附錄：截圖總表

| 規格 | 張數 | 編號 |
|---|---|---|
| 2 容器建置 | 7 + 證照 | S2-01 ～ S2-07 |
| 3 帳號整合 | 14 | S3-01 ～ S3-14 |
| 4 TLS 憑證 | 8 | S4-01 ～ S4-08 |
| 5 私有倉庫 | 7 | S5-01 ～ S5-07 |
| 6 GPU 監控 | 10 | S6-01 ～ S6-10 |
| 7 管理介面 | 7 | S7-01 ～ S7-07 |

## 附錄：目前尚未完成、驗收前需補齊的項目

| 規格 | 項目 | 現況 | 需要做的事 |
|---|---|---|---|
| 3 | **整合 AD 帳號系統**（S3-13） | Keycloak 目前只有本機帳號 | 取得院方 AD 連線資訊（LDAP URL、Bind DN、Users DN），在 Keycloak 建 User federation |
| 3 | **K8S 單一登入**（S3-14） | 未設定 | v1.25 需在 3 台 master 的 kube-apiserver 加 `--oidc-*` 參數並重啟；動到院方 control plane，需先取得院方同意與維護時段 |
| 3 | **Headlamp 單一登入** | 目前用 token 登入 | 依賴 K8S 單一登入完成後才能接 Keycloak |
| 3 | **DNS 解析之維護** | 目前只有叢集內 DNS（S3-06），服務以 IP 存取 | 確認院方是否要求 FQDN；若要，需決定 DNS 由誰維護 |
