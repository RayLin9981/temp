# 115TC059Q 既有叢集安裝手冊（規格二、第 3～7 項）

> 院方叢集：**K8s v1.25.6**，16 節點（k8sm01–03 master、dgx01–04 GPU、hp04–hp10 一般節點、ac922-01/02 為 POWER9 / ppc64le）。
> 前提：你有 `kubectl`（cluster-admin）與 `helm`，在 k8sm01 上以 root 操作。
>
> - 所有服務都用 **NodePort** 對外。
> - 所有 Pod 以 nodeAffinity 限制在 **x86（amd64）一般節點**，避開 ac922、DGX 與 master（Alloy 例外，需跑在每個 amd64 節點收 log）。
> - 版本以「支援 K8s 1.25」為前提，見各章說明。
> - 檔案一律 `cat <<EOF > FILE` 建立；`<<'EOF'`（有引號）代表內容**不展開**變數。

## 安裝順序與 NodePort

| 章節 | 規格 | 元件 | NodePort | 網址 |
|---|---|---|---|---|
| 1 | 4 | cert-manager（範例網站） | 30445 | `https://<NODE_IP>:30445` |
| 2 | 3 | Keycloak | 30443 | `https://<NODE_IP>:30443/admin` |
| 3 | 5 | Harbor | 30003（HTTPS）/ 30002（HTTP→轉 HTTPS） | `https://<NODE_IP>:30003` |
| 4 | 6 | Loki + Alloy + Grafana | 30446 | `http://<NODE_IP>:30446` |
| 5 | 7 | Headlamp | 30444 | `http://<NODE_IP>:30444` |

> cert-manager 先裝，Keycloak 與 Harbor 的 HTTPS 憑證都由它簽發。

---

## 0. 共用設定

### 0.1 變數檔（全部章節共用）

```bash
mkdir -p ~/fc-er && cd ~/fc-er
cat <<'EOF' > ~/fc-er/env.sh
# ===== 共用 =====
export NODE_IP="TODO"                   # 對外連線用的節點 IP（建議 hp04–hp10 其中一台）
export STORAGECLASS=""                  # 留空 = 使用叢集預設 StorageClass

# ===== 規格 4：cert-manager =====
export CERT_MANAGER_VERSION="v1.15.5"   # 支援 K8s 1.25 的最後一版（1.25–1.32）
export CA_ISSUER="fc-er-ca-issuer"
export CERT_DEMO_NS="cert-demo"
export CERT_DEMO_NODEPORT="30445"

# ===== 規格 3：Keycloak =====
export KC_NS="keycloak"
export KEYCLOAK_VERSION="26.8.0"
export KEYCLOAK_NODEPORT="30443"
export KC_HOST="${NODE_IP}"             # 之後有 DNS 可改成 keycloak.fc-er.internal
export KC_URL="https://${KC_HOST}:${KEYCLOAK_NODEPORT}"

# ===== 規格 5：Harbor =====
export HARBOR_NS="harbor"
export HARBOR_CHART_VERSION="1.19.2"    # Harbor v2.15.2
export HARBOR_HTTP_NODEPORT="30002"
export HARBOR_HTTPS_NODEPORT="30003"
export HARBOR_ADDR="${NODE_IP}:${HARBOR_HTTPS_NODEPORT}"   # docker / nerdctl 用的 registry 位址
export HARBOR_URL="https://${HARBOR_ADDR}"
export HARBOR_PROJECT="fc-er"
export HARBOR_DEMO_NODE="TODO"          # 拉 image 測試用的節點名稱（例 hp04）

# ===== 規格 6：Loki / Alloy / Grafana =====
export MON_NS="fc-er-monitoring"
export LOKI_CHART_VERSION="7.3.0"
export GRAFANA_NODEPORT="30446"
export PROM_URL="TODO"                  # 既有 Prometheus 叢集內網址，0.3 步查詢

# ===== 規格 7：Headlamp =====
export HEADLAMP_NS="headlamp"
export HEADLAMP_CHART_VERSION="0.45.0"
export HEADLAMP_NODEPORT="30444"
EOF

# 若之前已建立 phase1/phase2 變數檔，自動沿用 NODE_IP / PROM_URL
for f in phase1-env.sh phase2-env.sh; do
  [[ -f ~/fc-er/$f ]] || continue
  old_ip=$(bash -c "source ~/fc-er/$f 2>/dev/null; echo \$NODE_IP")
  old_prom=$(bash -c "source ~/fc-er/$f 2>/dev/null; echo \$PROM_URL")
  [[ "$old_ip" =~ ^[0-9.]+$ ]] && sed -i "s|NODE_IP=\"TODO\"|NODE_IP=\"$old_ip\"|" ~/fc-er/env.sh
  [[ "$old_prom" == http* ]] && sed -i "s|PROM_URL=\"TODO\"|PROM_URL=\"$old_prom\"|" ~/fc-er/env.sh
done

vi ~/fc-er/env.sh                        # 填 NODE_IP、HARBOR_DEMO_NODE、PROM_URL
source ~/fc-er/env.sh
grep -n '"TODO"' ~/fc-er/env.sh || echo "變數已填完"
```

### 0.2 密碼（只產生一次；若有舊的 phase1/phase2 密碼會沿用）

```bash
touch ~/fc-er/secrets.sh && chmod 600 ~/fc-er/secrets.sh
source ~/fc-er/phase1-secrets.sh 2>/dev/null; source ~/fc-er/phase2-secrets.sh 2>/dev/null
source ~/fc-er/secrets.sh
add_secret() {   # add_secret 變數名 產生方式
  local name=$1 val=${!1}
  grep -q "^export ${name}=" ~/fc-er/secrets.sh && return
  [[ -n "$val" ]] || val=$(eval "$2")
  echo "export ${name}=\"${val}\"" >> ~/fc-er/secrets.sh
}
add_secret KC_ADMIN_PASSWORD      'openssl rand -hex 12'
add_secret KC_DB_PASSWORD         'openssl rand -hex 16'
add_secret HARBOR_ADMIN_PASSWORD  'echo "Hb$(openssl rand -hex 8)A9"'   # Harbor 要求大小寫 + 數字
add_secret GRAFANA_ADMIN_PASSWORD 'openssl rand -hex 12'
source ~/fc-er/secrets.sh
cat ~/fc-er/secrets.sh                   # 請另行妥善保存
```

> **每開一個新 shell（含 tmux 新視窗）都要先執行**：
> `source ~/fc-er/env.sh && source ~/fc-er/secrets.sh`
> 沒載入時，變數會是空的（例如 openssl 會報 `invalid null value`）。

### 0.3 共用 affinity 與既有環境檢查

```bash
# 只排到 amd64 一般節點（避開 ac922、DGX、master）
cat <<'EOF' > ~/fc-er/affinity-amd64.yaml
nodeAffinity:
  requiredDuringSchedulingIgnoredDuringExecution:
    nodeSelectorTerms:
      - matchExpressions:
          - {key: kubernetes.io/arch, operator: In, values: [amd64]}
          - {key: node-role.kubernetes.io/gpu, operator: DoesNotExist}
          - {key: node-role.kubernetes.io/control-plane, operator: DoesNotExist}
EOF

kubectl version
kubectl get nodes -L kubernetes.io/arch,node-role.kubernetes.io/gpu   # ac922=ppc64le、DGX 有 gpu role
kubectl get sc                                                        # 需要 (default)，否則填 STORAGECLASS
# NodePort 是否被佔用
kubectl get svc -A | grep -E ":(30002|30003|30443|30444|30445|30446)/" || echo "NodePort 皆未被佔用"
# 既有元件
kubectl get crd | grep cert-manager.io || echo "未安裝 cert-manager"
kubectl -n kube-system get pods | grep metrics-server || echo "沒有 metrics-server"
kubectl get svc -A | grep -Ei "prometheus|grafana"                   # 找既有 Prometheus → PROM_URL
kubectl get pods -A -o wide | grep -i dcgm
# 既有 Prometheus 是否有 DCGM 指標
kubectl run promtest --rm -it --restart=Never --image=curlimages/curl:8.10.1 \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/arch":"amd64"}}}' -- \
  curl -s "${PROM_URL}/api/v1/query?query=count(DCGM_FI_DEV_GPU_UTIL)"
```

---

## 1. TLS 憑證管理：cert-manager（規格 4）

> 若 0.3 顯示 cert-manager **已安裝**，跳過 1.1（先用 `kubectl -n cert-manager get deploy -o wide` 確認版本），從 1.2 開始。

### 1.1 安裝 cert-manager v1.15.5

```bash
source ~/fc-er/env.sh && source ~/fc-er/secrets.sh
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

### 1.2 建立自簽 Root CA 與 CA ClusterIssuer

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

### 1.3 截圖用範例：HTTPS 網站 + 自動續期

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

#### 📸 規格 4 截圖

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

---

## 2. Keycloak（規格 3）

架構：PostgreSQL（StatefulSet + PVC）＋ Keycloak（官方 image），Keycloak 自己提供 HTTPS，經 NodePort 30443 對外。憑證由 cert-manager 簽發，Keycloak 26 會定期自動重載新憑證。

> 為什麼要 HTTPS：K8s API server 的 OIDC 規定 issuer 必須是 `https://`，之後串接 kubectl / Headlamp 時會用到。

### 2.1 TLS 憑證（cert-manager 簽發）

```bash
source ~/fc-er/env.sh && source ~/fc-er/secrets.sh
[[ "${NODE_IP}" =~ ^[0-9.]+$ ]] || { echo "NODE_IP 未設定：'${NODE_IP}'"; false; }
kubectl create ns ${KC_NS} --dry-run=client -o yaml | kubectl apply -f -

# 若之前用 openssl 建過 keycloak-tls，先刪掉，改由 cert-manager 管理
kubectl -n ${KC_NS} get secret keycloak-tls -o jsonpath='{.metadata.annotations}' 2>/dev/null \
  | grep -q cert-manager.io || kubectl -n ${KC_NS} delete secret keycloak-tls --ignore-not-found

cat <<EOF > ~/fc-er/keycloak-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: keycloak-tls
  namespace: ${KC_NS}
spec:
  secretName: keycloak-tls
  duration: 2160h           # 90 天
  renewBefore: 720h         # 到期前 30 天自動續期
  commonName: ${KC_HOST}
  dnsNames: [keycloak.fc-er.internal]
  ipAddresses: [${NODE_IP}]
  issuerRef:
    name: ${CA_ISSUER}
    kind: ClusterIssuer
EOF
kubectl apply -f ~/fc-er/keycloak-cert.yaml
kubectl -n ${KC_NS} get certificate keycloak-tls      # READY=True
```

> 若之後要用其他節點 IP 連，把 IP 加進 `ipAddresses` 後重新 apply，cert-manager 會自動重簽。

### 2.2 帳密 Secret

```bash
kubectl -n ${KC_NS} create secret generic keycloak-secrets \
  --from-literal=db-user=keycloak \
  --from-literal=db-password="${KC_DB_PASSWORD}" \
  --from-literal=admin-user=admin \
  --from-literal=admin-password="${KC_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 2.3 PostgreSQL

```bash
cat <<EOF > ~/fc-er/keycloak-postgres.yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: postgres
  namespace: ${KC_NS}
spec:
  serviceName: postgres
  replicas: 1
  selector:
    matchLabels: {app: postgres}
  template:
    metadata:
      labels: {app: postgres}
    spec:
      affinity:
$(sed 's/^/        /' ~/fc-er/affinity-amd64.yaml)
      containers:
        - name: postgres
          image: postgres:17
          env:
            - {name: POSTGRES_DB, value: keycloak}
            - name: POSTGRES_USER
              valueFrom: {secretKeyRef: {name: keycloak-secrets, key: db-user}}
            - name: POSTGRES_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-secrets, key: db-password}}
            - {name: PGDATA, value: /var/lib/postgresql/data/pgdata}
          ports:
            - containerPort: 5432
          readinessProbe:
            exec: {command: ["pg_isready", "-U", "keycloak", "-d", "keycloak"]}
            periodSeconds: 10
          resources:
            requests: {cpu: 100m, memory: 256Mi}
          volumeMounts:
            - {name: data, mountPath: /var/lib/postgresql/data}
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: [ReadWriteOnce]
$( [[ -n "${STORAGECLASS}" ]] && echo "        storageClassName: ${STORAGECLASS}" )
        resources:
          requests:
            storage: 10Gi
---
apiVersion: v1
kind: Service
metadata:
  name: postgres
  namespace: ${KC_NS}
spec:
  selector: {app: postgres}
  ports:
    - port: 5432
EOF
kubectl apply -f ~/fc-er/keycloak-postgres.yaml
kubectl -n ${KC_NS} rollout status sts/postgres --timeout=5m
kubectl -n ${KC_NS} get pods,pvc
```

### 2.4 Keycloak（NodePort 30443）

```bash
cat <<EOF > ~/fc-er/keycloak.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
  namespace: ${KC_NS}
spec:
  replicas: 1
  selector:
    matchLabels: {app: keycloak}
  template:
    metadata:
      labels: {app: keycloak}
    spec:
      affinity:
$(sed 's/^/        /' ~/fc-er/affinity-amd64.yaml)
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
          args: ["start"]
          env:
            # 對外網址（含 NodePort），token 的 issuer 會是 <KC_URL>/realms/<realm>
            - {name: KC_HOSTNAME, value: "${KC_URL}"}
            - {name: KC_HTTPS_CERTIFICATE_FILE, value: /opt/keycloak/conf/tls/tls.crt}
            - {name: KC_HTTPS_CERTIFICATE_KEY_FILE, value: /opt/keycloak/conf/tls/tls.key}
            - {name: KC_HTTP_ENABLED, value: "false"}
            - {name: KC_HEALTH_ENABLED, value: "true"}
            - {name: KC_DB, value: postgres}
            - {name: KC_DB_URL, value: "jdbc:postgresql://postgres:5432/keycloak"}
            - name: KC_DB_USERNAME
              valueFrom: {secretKeyRef: {name: keycloak-secrets, key: db-user}}
            - name: KC_DB_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-secrets, key: db-password}}
            - name: KC_BOOTSTRAP_ADMIN_USERNAME
              valueFrom: {secretKeyRef: {name: keycloak-secrets, key: admin-user}}
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-secrets, key: admin-password}}
          ports:
            - {name: https, containerPort: 8443}
            - {name: management, containerPort: 9000}
          readinessProbe:
            httpGet: {path: /health/ready, port: 9000, scheme: HTTPS}
            initialDelaySeconds: 30
            periodSeconds: 10
          livenessProbe:
            httpGet: {path: /health/live, port: 9000, scheme: HTTPS}
            initialDelaySeconds: 90
            periodSeconds: 20
          resources:
            requests: {cpu: 500m, memory: 1Gi}
            limits: {memory: 2Gi}
          volumeMounts:
            - {name: tls, mountPath: /opt/keycloak/conf/tls, readOnly: true}
      volumes:
        - name: tls
          secret:
            secretName: keycloak-tls
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
  namespace: ${KC_NS}
spec:
  type: NodePort
  selector: {app: keycloak}
  ports:
    - name: https
      port: 8443
      targetPort: 8443
      nodePort: ${KEYCLOAK_NODEPORT}
EOF
kubectl apply -f ~/fc-er/keycloak.yaml
kubectl -n ${KC_NS} rollout status deploy/keycloak --timeout=10m
kubectl -n ${KC_NS} get pods,svc -o wide
```

### 2.5 驗證

```bash
curl -s --cacert ~/fc-er/fc-er-root-ca.crt ${KC_URL}/realms/master/.well-known/openid-configuration | jq .issuer
echo "管理介面：${KC_URL}/admin   帳號：admin   密碼：${KC_ADMIN_PASSWORD}"
```

> `KC_BOOTSTRAP_ADMIN_*` 建立的是**臨時**管理者。登入後在 master realm 建立正式管理者，再刪除臨時帳號。

### 2.6 📸 規格 3 截圖

- `kubectl -n keycloak get pods,svc,pvc,certificate`（NodePort 30443、憑證 READY）
- 瀏覽器 `https://<NODE_IP>:30443/admin` 登入後首頁（網址列鎖頭正常，需先信任 Root CA，見 1.3）
- 建立 realm `fc-er` → Users → 新增測試使用者 → 使用者清單

---

## 3. 私有映像倉庫：Harbor（規格 5）

架構：Harbor helm chart，`expose.type=nodePort`，由 Harbor 內建 nginx 終止 TLS；憑證由 cert-manager 簽發。Harbor 所有元件都排到 amd64 一般節點。

### 3.1 TLS 憑證

```bash
source ~/fc-er/env.sh && source ~/fc-er/secrets.sh
kubectl create ns ${HARBOR_NS} --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF > ~/fc-er/harbor-cert.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: harbor-tls
  namespace: ${HARBOR_NS}
spec:
  secretName: harbor-tls
  duration: 8760h           # 1 年（Harbor nginx 不會自動重載，續期後需重啟 harbor-nginx）
  renewBefore: 720h
  commonName: ${NODE_IP}
  dnsNames: [harbor.fc-er.internal]
  ipAddresses: [${NODE_IP}]
  issuerRef:
    name: ${CA_ISSUER}
    kind: ClusterIssuer
EOF
kubectl apply -f ~/fc-er/harbor-cert.yaml
kubectl -n ${HARBOR_NS} get certificate harbor-tls      # READY=True

kubectl -n ${HARBOR_NS} create secret generic harbor-admin \
  --from-literal=HARBOR_ADMIN_PASSWORD="${HARBOR_ADMIN_PASSWORD}" \
  --dry-run=client -o yaml | kubectl apply -f -
```

### 3.2 helm 安裝（NodePort 30003）

```bash
helm repo add harbor https://helm.goharbor.io && helm repo update

{
cat <<EOF
externalURL: ${HARBOR_URL}
expose:
  type: nodePort
  tls:
    enabled: true
    certSource: secret
    secret:
      secretName: harbor-tls
  nodePort:
    name: harbor
    ports:
      http:
        port: 80
        nodePort: ${HARBOR_HTTP_NODEPORT}
      https:
        port: 443
        nodePort: ${HARBOR_HTTPS_NODEPORT}
existingSecretAdminPassword: harbor-admin
existingSecretAdminPasswordKey: HARBOR_ADMIN_PASSWORD
persistence:
  enabled: true
  resourcePolicy: keep          # helm uninstall 時保留 PVC
  persistentVolumeClaim:
    registry:
      size: 200Gi
    jobservice:
      jobLog:
        size: 1Gi
    database:
      size: 5Gi
    redis:
      size: 1Gi
    trivy:
      size: 5Gi
metrics:
  enabled: false
# ----- 所有元件只排到 amd64 一般節點 -----
nginx:
  affinity: &amd64
EOF
sed 's/^/    /' ~/fc-er/affinity-amd64.yaml
cat <<'EOF'
portal:     {affinity: *amd64}
core:       {affinity: *amd64}
jobservice: {affinity: *amd64}
registry:   {affinity: *amd64}
trivy:      {affinity: *amd64}
exporter:   {affinity: *amd64}
database:
  internal: {affinity: *amd64}
redis:
  internal: {affinity: *amd64}
EOF
} > ~/fc-er/harbor-values.yaml

# 指定 StorageClass（STORAGECLASS 有填才會帶入）
SC_ARGS=()
if [[ -n "${STORAGECLASS}" ]]; then
  for c in registry jobservice.jobLog database redis trivy; do
    SC_ARGS+=(--set persistence.persistentVolumeClaim.${c}.storageClass=${STORAGECLASS})
  done
fi

helm upgrade --install harbor harbor/harbor -n ${HARBOR_NS} \
  --version ${HARBOR_CHART_VERSION} -f ~/fc-er/harbor-values.yaml "${SC_ARGS[@]}" \
  --wait --timeout 15m
kubectl -n ${HARBOR_NS} get pods,svc,pvc -o wide
```

### 3.3 驗證

```bash
curl -s --cacert ~/fc-er/fc-er-root-ca.crt ${HARBOR_URL}/api/v2.0/ping; echo          # Pong
curl -s --cacert ~/fc-er/fc-er-root-ca.crt ${HARBOR_URL}/api/v2.0/systeminfo | jq '{harbor_version, external_url}'
echo "Harbor：${HARBOR_URL}   帳號：admin   密碼：${HARBOR_ADMIN_PASSWORD}"
```

### 3.4 建立私有專案與 pull 用 robot 帳號

```bash
HAPI="${HARBOR_URL}/api/v2.0"
hcurl() { curl -s --cacert ~/fc-er/fc-er-root-ca.crt -u "admin:${HARBOR_ADMIN_PASSWORD}" -H "Content-Type: application/json" "$@"; }

hcurl -X POST -d "{\"project_name\":\"${HARBOR_PROJECT}\",\"metadata\":{\"public\":\"false\"}}" \
  ${HAPI}/projects -w "%{http_code}\n"                       # 201（已存在會回 409）

hcurl -X POST -d "{\"name\":\"k8s-pull\",\"level\":\"project\",\"duration\":-1,
  \"permissions\":[{\"kind\":\"project\",\"namespace\":\"${HARBOR_PROJECT}\",
  \"access\":[{\"resource\":\"repository\",\"action\":\"pull\"}]}]}" \
  ${HAPI}/robots > ~/fc-er/harbor-robot.json
chmod 600 ~/fc-er/harbor-robot.json
jq -r .name ~/fc-er/harbor-robot.json                         # 例 robot$fc-er+k8s-pull
```

### 3.5 讓節點信任 Harbor 憑證

推送端（k8sm01）與拉取端（`HARBOR_DEMO_NODE`）都要信任 Root CA。用 containerd 的 `certs.d` 只對這個 registry 生效，不影響其他設定。

```bash
# 在 k8sm01 與 ${HARBOR_DEMO_NODE} 上各執行一次（DEMO 節點請 scp 過去或 ssh 執行）
mkdir -p /etc/containerd/certs.d/${HARBOR_ADDR}
cp ~/fc-er/fc-er-root-ca.crt /etc/containerd/certs.d/${HARBOR_ADDR}/ca.crt
cat <<EOF > /etc/containerd/certs.d/${HARBOR_ADDR}/hosts.toml
server = "${HARBOR_URL}"

[host."${HARBOR_URL}"]
  capabilities = ["pull", "resolve", "push"]
  ca = "/etc/containerd/certs.d/${HARBOR_ADDR}/ca.crt"
EOF

# 確認 containerd 的 CRI 有讀 certs.d（kubelet 拉 image 要靠這個）
grep -n "config_path" /etc/containerd/config.toml
```

> - `config_path` 有指到 `/etc/containerd/certs.d`：不需重啟，立即生效。
> - **沒有** `config_path`（舊版 kubespray）：改用系統信任 —
>   `cp ~/fc-er/fc-er-root-ca.crt /usr/local/share/ca-certificates/fc-er-root-ca.crt && update-ca-certificates && systemctl restart containerd`。
>   重啟 containerd 不會停掉執行中的容器，但**仍請先取得院方同意**，且只做在 DEMO 節點。

在 DEMO 節點用 ssh 一次做完的寫法：

```bash
ssh ${HARBOR_DEMO_NODE} "mkdir -p /etc/containerd/certs.d/${HARBOR_ADDR}"
scp ~/fc-er/fc-er-root-ca.crt /etc/containerd/certs.d/${HARBOR_ADDR}/hosts.toml \
  ${HARBOR_DEMO_NODE}:/etc/containerd/certs.d/${HARBOR_ADDR}/
ssh ${HARBOR_DEMO_NODE} "mv /etc/containerd/certs.d/${HARBOR_ADDR}/fc-er-root-ca.crt /etc/containerd/certs.d/${HARBOR_ADDR}/ca.crt; grep -n config_path /etc/containerd/config.toml"
```

### 3.6 推送 image（📸 規格 5：存放映像檔）

kubespray 預設會裝 `nerdctl`，用它推送：

```bash
which nerdctl || echo "沒有 nerdctl，改用下方 ctr 指令"

nerdctl pull --platform linux/amd64 docker.io/library/nginx:1.27
nerdctl tag docker.io/library/nginx:1.27 ${HARBOR_ADDR}/${HARBOR_PROJECT}/nginx:1.27
echo "${HARBOR_ADMIN_PASSWORD}" | nerdctl login ${HARBOR_ADDR} -u admin --password-stdin
nerdctl push ${HARBOR_ADDR}/${HARBOR_PROJECT}/nginx:1.27
```

> 沒有 nerdctl 時用 `ctr`：
> ```bash
> ctr images pull --platform linux/amd64 docker.io/library/nginx:1.27
> ctr images tag docker.io/library/nginx:1.27 ${HARBOR_ADDR}/${HARBOR_PROJECT}/nginx:1.27
> ctr images push --hosts-dir /etc/containerd/certs.d --user "admin:${HARBOR_ADMIN_PASSWORD}" \
>   ${HARBOR_ADDR}/${HARBOR_PROJECT}/nginx:1.27
> ```

### 3.7 平台從 Harbor 拉取（📸 規格 5：提供給容器平台使用）

```bash
kubectl create ns harbor-demo --dry-run=client -o yaml | kubectl apply -f -
kubectl -n harbor-demo create secret docker-registry harbor-pull \
  --docker-server=${HARBOR_ADDR} \
  --docker-username="$(jq -r .name ~/fc-er/harbor-robot.json)" \
  --docker-password="$(jq -r .secret ~/fc-er/harbor-robot.json)" \
  --dry-run=client -o yaml | kubectl apply -f -

cat <<EOF > ~/fc-er/harbor-demo.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: harbor-demo
  namespace: harbor-demo
spec:
  replicas: 2
  selector:
    matchLabels: {app: harbor-demo}
  template:
    metadata:
      labels: {app: harbor-demo}
    spec:
      nodeSelector:
        kubernetes.io/hostname: ${HARBOR_DEMO_NODE}     # 只有這台信任 Harbor 憑證
      imagePullSecrets:
        - name: harbor-pull
      containers:
        - name: nginx
          image: ${HARBOR_ADDR}/${HARBOR_PROJECT}/nginx:1.27
          imagePullPolicy: Always
          ports:
            - containerPort: 80
EOF
kubectl apply -f ~/fc-er/harbor-demo.yaml
kubectl -n harbor-demo rollout status deploy/harbor-demo
kubectl -n harbor-demo get pods -o wide
kubectl -n harbor-demo get events --sort-by=.lastTimestamp | grep -E "Pulling|Pulled"
```

### 3.8 📸 規格 5 截圖清單

| # | 畫面 | 對應原文 |
|---|---|---|
| ① | `kubectl -n harbor get pods,svc,pvc -o wide`（NodePort 30003） | 私有倉庫建置 |
| ② | 瀏覽器 `https://<NODE_IP>:30003` 登入後 → Projects → `fc-er`（Access Level: **Private**） | 私有倉庫 |
| ③ | `nerdctl push` 成功的終端畫面 | 可存放容器映像檔 |
| ④ | Harbor UI → `fc-er` → Repositories → `nginx:1.27`（含 digest、推送時間） | 可存放容器映像檔 |
| ⑤ | `kubectl -n harbor-demo get pods -o wide` + Events 的 `Successfully pulled image "<NODE_IP>:30003/fc-er/nginx:1.27"` | 提供給容器平台使用 |
| ⑥ | Harbor UI → `fc-er` → Robot Accounts（`k8s-pull`，僅 pull 權限） | 權限控管（加分） |

截完圖可以刪除測試：`kubectl delete ns harbor-demo`

---

## 4. 監控：Loki + Alloy + Grafana Dashboard（規格 6）

架構：

```
各節點 Pod log ──Alloy(DaemonSet)──▶ Loki ─┐
                                            ├──▶ Grafana（NodePort 30446）
既有 Prometheus（含 DCGM 指標）──────────────┘     └ Dashboard：GPU 指標 + Logs 同一頁
```

> 不動院方既有的 Prometheus / Grafana，另外起一個 Grafana 把兩個資料源接在一起。若院方要用既有 Grafana，只要加 Loki 資料源並匯入 4.4 的 Dashboard JSON 即可。

```bash
source ~/fc-er/env.sh && source ~/fc-er/secrets.sh
kubectl create ns ${MON_NS} --dry-run=client -o yaml | kubectl apply -f -
helm repo add grafana-community https://grafana-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

### 4.1 Loki（Monolithic，檔案系統儲存）

```bash
{
cat <<'EOF'
global:
  dnsService: coredns          # kubespray 的 DNS Service 叫 coredns（chart 預設 kube-dns，會讓 loki-gateway 回 502）
  dnsNamespace: kube-system
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

### 4.2 Alloy（每個 amd64 節點收集 Pod log → Loki）

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

### 4.3 Grafana（NodePort 30446，接既有 Prometheus + Loki）

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
# 自訂 Dashboard（4.4 的 ConfigMap）由 sidecar 載入
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

### 4.4 自訂 Dashboard：GPU 指標 + Logs 同一頁

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

### 4.5（選做）測試 Pod：讓 Log 與 GPU 指標對得起來

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

### 4.6 📸 規格 6 截圖

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

## 5. 網頁管理介面：Headlamp（規格 7）

```bash
source ~/fc-er/env.sh && source ~/fc-er/secrets.sh
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ && helm repo update

{
cat <<EOF
service:
  type: NodePort
  port: 80
  nodePort: ${HEADLAMP_NODEPORT}
config:
  inCluster: true
clusterRoleBinding:
  create: false          # 不給 Headlamp 本身 cluster-admin，權限依登入的 token 決定
affinity:
EOF
sed 's/^/  /' ~/fc-er/affinity-amd64.yaml
} > ~/fc-er/headlamp-values.yaml

helm upgrade --install headlamp headlamp/headlamp -n ${HEADLAMP_NS} --create-namespace \
  --version ${HEADLAMP_CHART_VERSION} -f ~/fc-er/headlamp-values.yaml --wait
kubectl -n ${HEADLAMP_NS} get pods,svc -o wide
```

### 5.1 登入用 token（OIDC 串好之前先用這個）

```bash
kubectl -n ${HEADLAMP_NS} create serviceaccount headlamp-admin --dry-run=client -o yaml | kubectl apply -f -
kubectl create clusterrolebinding headlamp-admin \
  --clusterrole=cluster-admin --serviceaccount=${HEADLAMP_NS}:headlamp-admin \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ${HEADLAMP_NS} create token headlamp-admin --duration=24h
```

瀏覽器開 `http://<NODE_IP>:30444`，貼上 token 登入。

> 若叢集沒有 metrics-server（0.3 檢查），Headlamp 看不到 CPU / Memory 用量。安裝前請先取得院方同意：
> ```bash
> helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ && helm repo update
> helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
>   --set 'args={--kubelet-insecure-tls}' --wait
> kubectl top nodes
> ```

### 5.2 📸 規格 7 截圖

- `kubectl -n headlamp get pods,svc`（NodePort 30444）
- Headlamp 首頁（叢集總覽）
- 右上 **Create** 貼上以下 YAML → 建立成功 → Workloads 清單看到 `headlamp-demo`

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

- Cluster / Nodes 頁的 CPU、Memory 用量圖

---

## 附錄 A：驗收截圖總表（規格二、第 3～7 項）

| 規格 | 截圖 | 章節 |
|---|---|---|
| 3 帳號建立 | Keycloak realm / Users 清單 | 2.6 |
| 4 憑證管理系統 | `kubectl -n cert-manager get pods`、`kubectl get clusterissuer` | 1.3 |
| 4 憑證簽發 | `kubectl get certificate -A`（cert-demo、keycloak、harbor 都 READY） | 1.3 |
| 4 自動續期 | `describe certificate cert-demo-tls` 的 Revision 增加 | 1.3 |
| 4 部署 | 瀏覽器 30445 / 30443 / 30003 的憑證資訊（簽發者 FC-ER Root CA） | 1.3、2.6、3.8 |
| 5 私有倉庫 | Harbor 專案 `fc-er`（Private） | 3.8 |
| 5 存放映像 | `nerdctl push` + Harbor Repositories 頁 | 3.8 |
| 5 提供給平台 | `harbor-demo` Pod 的 Successfully pulled | 3.8 |
| 6 GPU Operator | `kubectl get pods -A \| grep -E "gpu-operator\|dcgm"` | 4.6 |
| 6 Metrics / Logs | Grafana 資料源 Prometheus、Loki test 成功 | 4.6 |
| 6 GPU 儀表板 | NVIDIA DCGM Exporter Dashboard | 4.6 |
| 6 整合查詢 | FC-ER GPU Metrics + Logs Dashboard、Explore Split | 4.6 |
| 7 管理介面 | Headlamp 建立 Deployment、資源用量圖 | 5.2 |

## 附錄 B：常見問題

| 狀況 | 排查 |
|---|---|
| openssl / YAML 裡的值是空的 | 新 shell 沒有 `source ~/fc-er/env.sh && source ~/fc-er/secrets.sh` |
| Pod 一直 Pending | `kubectl describe pod` 看 Events：PVC 沒有 StorageClass（填 `STORAGECLASS`），或 affinity 找不到符合的節點（確認 0.3 的節點 label） |
| Pod `exec format error` | 被排到 ac922（ppc64le），確認 affinity 有套用 |
| cert-manager webhook 逾時 | API server 連不到 webhook Pod；確認 Pod 在 amd64 節點、NetworkPolicy 沒擋 |
| Certificate 一直 `READY=False` | `kubectl describe certificate`、`kubectl get certificaterequest -A`；CA ClusterIssuer 要先 Ready |
| Keycloak Pod 一直重啟 | `kubectl -n keycloak logs deploy/keycloak`；多半是 DB 連不上或憑證 Secret 不存在 |
| Keycloak 登入後跳錯網址 | `KC_HOSTNAME` 與實際網址（IP、port）不一致，改 `KC_URL` 後重新 apply |
| Keycloak readinessProbe 失敗 | 若此版本管理埠不是 HTTPS，把 probe 的 `scheme` 改成 `HTTP` |
| `nerdctl push` 出現 x509 錯誤 | k8sm01 的 `/etc/containerd/certs.d/<NODE_IP>:30003/ca.crt` 沒放好 |
| `harbor-demo` 出現 `ErrImagePull` x509 | DEMO 節點沒有信任 CA，或 containerd 沒設 `config_path`（見 3.5） |
| `harbor-demo` 出現 401 / unauthorized | `harbor-pull` Secret 的 robot 帳密錯誤，或 `--docker-server` 與 image 位址不一致 |
| Harbor 憑證續期後瀏覽器仍顯示舊憑證 | `kubectl -n harbor rollout restart deploy/harbor-nginx` |
| Grafana 的 Prometheus 資料源失敗 | `PROM_URL` 錯誤，用 0.3 的 curl 測試同一個 URL |
| Dashboard GPU 圖沒資料 | Prometheus 沒有 DCGM 指標，或節點標籤不是 `Hostname`（見 4.4） |
| Logs 面板空白 | `kubectl -n fc-er-monitoring logs ds/alloy`；確認 `loki-gateway` Service 存在 |
| NodePort 連不到 | 院方或節點防火牆擋了 30002/30003/30443–30446 |
