# 既有叢集 — Phase 1：Headlamp + Keycloak（NodePort）

> 前提：院方已有 K8s 叢集，你手上有可用的 `kubectl`（cluster-admin）與 `helm`。
> 本階段只求「裝起來、能用、能截圖」。OIDC 串接（Headlamp 用 Keycloak 登入）留到下一階段。

## 0. 變數與前置檢查

```bash
mkdir -p ~/fc-er && cd ~/fc-er
cat <<'EOF' > ~/fc-er/phase1-env.sh
# ===== Phase 1 變數 =====
export NODE_IP="TODO"                 # 任一 worker/master 節點 IP（NodePort 在每個節點都可連）
export KC_HOST="${NODE_IP}"           # 之後有 DNS 可改成 keycloak.fc-er.internal

export HEADLAMP_NS="headlamp"
export HEADLAMP_CHART_VERSION="0.45.0"
export HEADLAMP_NODEPORT="30444"

export KC_NS="keycloak"
export KEYCLOAK_VERSION="26.8.0"
export KEYCLOAK_NODEPORT="30443"
export KC_URL="https://${KC_HOST}:${KEYCLOAK_NODEPORT}"

export STORAGECLASS=""                # 留空 = 使用叢集預設 StorageClass
EOF
vi ~/fc-er/phase1-env.sh              # 填 NODE_IP
source ~/fc-er/phase1-env.sh

# 密碼只產生一次
[[ -f ~/fc-er/phase1-secrets.sh ]] || cat <<EOF > ~/fc-er/phase1-secrets.sh
export KC_ADMIN_PASSWORD="$(openssl rand -hex 12)"
export KC_DB_PASSWORD="$(openssl rand -hex 16)"
EOF
chmod 600 ~/fc-er/phase1-secrets.sh && source ~/fc-er/phase1-secrets.sh
```

檢查既有叢集：

```bash
kubectl version
kubectl get nodes -o wide
kubectl get sc                                    # 要有一個 (default)，Keycloak 的 PostgreSQL 需要 PVC
kubectl get svc -A | grep -E ":(${HEADLAMP_NODEPORT}|${KEYCLOAK_NODEPORT})/" || echo "NodePort 未被佔用"
kubectl -n kube-system get pods | grep metrics-server || echo "沒有 metrics-server → Headlamp 看不到 CPU/Memory 用量"
```

> 沒有預設 StorageClass 時，把 `STORAGECLASS` 填成 `kubectl get sc` 裡的名稱。

---

## 1. Headlamp（規格 7）

```bash
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/ && helm repo update

cat <<EOF > ~/fc-er/headlamp-values.yaml
service:
  type: NodePort
  port: 80
  nodePort: ${HEADLAMP_NODEPORT}
config:
  inCluster: true
clusterRoleBinding:
  create: false          # 不給 Headlamp 本身 cluster-admin，權限依登入的 token 決定
EOF

helm upgrade --install headlamp headlamp/headlamp -n ${HEADLAMP_NS} --create-namespace \
  --version ${HEADLAMP_CHART_VERSION} -f ~/fc-er/headlamp-values.yaml --wait
kubectl -n ${HEADLAMP_NS} get pods,svc
```

### 1.1 登入用 token（OIDC 串好之前先用這個）

```bash
kubectl -n ${HEADLAMP_NS} create serviceaccount headlamp-admin
kubectl create clusterrolebinding headlamp-admin \
  --clusterrole=cluster-admin --serviceaccount=${HEADLAMP_NS}:headlamp-admin
kubectl -n ${HEADLAMP_NS} create token headlamp-admin --duration=24h
```

瀏覽器開 `http://${NODE_IP}:30444`，貼上 token 登入。

### 1.2 驗收截圖（規格 7）

- `kubectl -n headlamp get pods,svc`（NodePort 30444）
- Headlamp 首頁
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
      containers:
        - name: nginx
          image: nginx:1.27
          resources:
            requests: {cpu: 50m, memory: 64Mi}
```

- Cluster / Nodes 頁的 CPU、Memory 用量（需要 metrics-server）

> 若叢集沒有 metrics-server：
> ```bash
> helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/ && helm repo update
> helm upgrade --install metrics-server metrics-server/metrics-server -n kube-system \
>   --set 'args={--kubelet-insecure-tls}' --wait
> kubectl top nodes
> ```
> 安裝到院方既有叢集前，先確認院方同意。

---

## 2. Keycloak（規格 3）

架構：PostgreSQL（StatefulSet + PVC）＋ Keycloak（官方 image，Deployment），Keycloak 自己提供 HTTPS，經 NodePort 30443 對外。

> 為什麼要 HTTPS：K8s API server 的 OIDC 規定 issuer 必須是 `https://`，之後串接 kubectl / Headlamp 時會用到。這裡先用 openssl 自簽憑證。

### 2.1 自簽 TLS 憑證

```bash
cd ~/fc-er
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 825 \
  -keyout keycloak.key -out keycloak.crt \
  -subj "/CN=${KC_HOST}" \
  -addext "subjectAltName=IP:${NODE_IP},DNS:keycloak.fc-er.internal"
chmod 600 keycloak.key

kubectl create ns ${KC_NS} --dry-run=client -o yaml | kubectl apply -f -
kubectl -n ${KC_NS} create secret tls keycloak-tls --cert=keycloak.crt --key=keycloak.key \
  --dry-run=client -o yaml | kubectl apply -f -
```

> 若之後要用其他節點 IP 連，把那些 IP 也加進 `subjectAltName`（`IP:x.x.x.x,IP:y.y.y.y`）後重新產生。

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
      containers:
        - name: keycloak
          image: quay.io/keycloak/keycloak:${KEYCLOAK_VERSION}
          args: ["start"]
          env:
            # 對外網址（含 NodePort），token 的 issuer 會是 \${KC_URL}/realms/<realm>
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
kubectl -n ${KC_NS} get pods,svc
```

### 2.5 驗證

```bash
curl -sk ${KC_URL}/realms/master/.well-known/openid-configuration | jq .issuer
echo "管理介面：${KC_URL}/admin   帳號：admin   密碼：${KC_ADMIN_PASSWORD}"
```

瀏覽器開 `https://${NODE_IP}:30443/admin`（自簽憑證會出現警告，Mac 可把 `keycloak.crt` 加入鑰匙圈信任：
`sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain keycloak.crt`）。

> `KC_BOOTSTRAP_ADMIN_*` 建立的是**臨時**管理者。登入後請在 master realm 建立正式管理者帳號，再刪除臨時帳號。

### 2.6 驗收截圖（規格 3：帳號建立）

- `kubectl -n keycloak get pods,svc,pvc`（NodePort 30443）
- Keycloak 管理介面登入後首頁
- 建一個 realm（例如 `fc-er`）→ Users → 新增測試使用者 → 使用者清單

---

## 常見問題

| 狀況 | 排查 |
|---|---|
| Keycloak Pod 一直重啟 | `kubectl -n keycloak logs deploy/keycloak`；多半是 DB 連不上（看 postgres Pod）或憑證路徑錯誤 |
| 瀏覽器開得到但登入後跳錯網址 | `KC_HOSTNAME` 與實際網址（IP、port）不一致，改 `KC_URL` 後重新 apply |
| readinessProbe 一直失敗 | 確認 `KC_HEALTH_ENABLED=true`；若此版本的管理埠不是 HTTPS，把 probe 的 `scheme` 改成 `HTTP` |
| PVC 一直 Pending | 叢集沒有預設 StorageClass，填 `STORAGECLASS` 後刪掉 StatefulSet 和 PVC 重建 |
| NodePort 連不到 | 院方防火牆或節點防火牆擋了 30443/30444 |
