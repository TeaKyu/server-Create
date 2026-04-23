# OpenBao 시크릿 + 인증서 통합 관리 가이드

Sealed Secrets + cert-manager를 **OpenBao**(Vault 오픈소스 포크) 하나로 통합하는 가이드.
시크릿 관리(KV Engine)와 인증서 발급(PKI Engine)을 한 곳에서 운영한다.

---

## 배경

### OpenBao란?

HashiCorp Vault가 2023년 BSL 라이선스로 전환하면서, Linux Foundation이 Vault 1.14를 포크한 **진짜 오픈소스** 프로젝트.

| 항목 | Vault | OpenBao |
|------|-------|---------|
| 라이선스 | BSL 1.1 (비상업적 제한) | MPL 2.0 (완전 오픈소스) |
| 포크 기준 | — | Vault 1.14 |
| 현재 버전 | 1.17+ | v2.5.2 (2026-03) |
| CLI 명령어 | `vault` | `bao` (문법 동일) |
| API | — | Vault 1.14 API 호환 |
| 컨테이너 | hashicorp/vault | quay.io/openbao/openbao |
| cert-manager 연동 | Vault Issuer | Vault Issuer 그대로 사용 가능 |

### 06-01(SOPS) 가이드와의 비교

| 항목 | 06-01 (SOPS) + 06-02 (cert-manager) | 06-03 (OpenBao) |
|------|--------------------------------------|-----------------|
| 시크릿 관리 | SOPS (Git 암호화) | OpenBao KV Engine |
| 인증서 관리 | cert-manager (별도) | OpenBao PKI Engine + cert-manager |
| 서버 컴포넌트 | 없음 (CLI만) | OpenBao 서버 (~300-600MB) |
| 설정 복잡도 | 낮음 | 중~높음 |
| 운영 부담 | 거의 없음 | Unseal, 백업, 토큰 관리 |
| 확장성 | 시크릿 암호화만 | 동적 시크릿, PKI, 감사로그 등 |
| 추천 규모 | 앱 2-5개 | 앱 10개 이상 또는 보안 감사 필요 |
| 현재 적용 | ✅ dev 적용 완료 | ⬜ 미적용 (향후 확장 시 참고) |

> **참고**: 현재 규모(앱 2-3개, 내부망)에서는 06-01(SOPS)이 적용되어 있다.
> 이 가이드는 향후 규모 확장이나 보안 감사 요구 시를 대비한 문서이다.

---

## 전제 조건

| 항목 | 상태 |
|------|------|
| 01-배포-가이드.md | 완료 |
| ArgoCD | 설치됨 (argocd 네임스페이스) |
| cert-manager | 설치됨 (cert-manager 네임스페이스) |
| k3s 마스터 노드 SSH 접속 | 가능 |
| Helm 3 | 설치됨 |

---

## 전체 아키텍처

```
[개발자 / 관리자]
    │
    │  bao kv put / bao write pki/...
    ▼
┌─────────────────────────────────────────────────────┐
│  OpenBao Server (openbao 네임스페이스)                │
│                                                      │
│  ┌──────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │ KV Engine    │  │ PKI Engine   │  │ K8s Auth   │ │
│  │ (시크릿 저장) │  │ (인증서 발급) │  │ (파드 인증) │ │
│  └──────┬───────┘  └──────┬───────┘  └─────┬──────┘ │
│         │                 │                │         │
└─────────┼─────────────────┼────────────────┼─────────┘
          │                 │                │
          ▼                 ▼                │
   ┌──────────────┐  ┌──────────────┐       │
   │ ESO          │  │ cert-manager │       │
   │ (K8s Secret  │  │ (Vault       │       │
   │  자동 생성)   │  │  Issuer)     │       │
   └──────┬───────┘  └──────┬───────┘       │
          │                 │                │
          ▼                 ▼                │
   K8s Secret          K8s TLS Secret       │
   (DB 비밀번호 등)    (인증서)               │
          │                 │                │
          ▼                 ▼                │
   ┌──────────────────────────────────┐     │
   │  insideinfo-api / web 파드       │◀────┘
   │  (시크릿을 마운트/환경변수로 사용)  │
   └──────────────────────────────────┘
```

---

## Part 1: OpenBao 설치

### Step 1: Helm Chart 설치

k3s 마스터 노드에서 실행:

```bash
# Helm repo 추가
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
```

### Step 2: values 파일 작성

`/opt/k3s-lab/openbao-values.yaml`:

```yaml
server:
  image:
    repository: quay.io/openbao/openbao
    tag: "2.5.2"

  standalone:
    enabled: true
    config: |
      ui = true

      listener "tcp" {
        tls_disable = 1
        address     = "[::]:8200"
        cluster_address = "[::]:8201"
      }

      storage "raft" {
        path = "/openbao/data"
      }

  dataStorage:
    enabled: true
    size: 2Gi
    # K3s 기본 storageClass (local-path) 사용

  resources:
    requests:
      memory: 256Mi
      cpu: 250m
    limits:
      memory: 512Mi
      cpu: 500m

# Agent Injector (ESO 사용 시 불필요하지만, 향후 활용 가능)
injector:
  enabled: true
  replicas: 1
  resources:
    requests:
      memory: 64Mi
      cpu: 100m
    limits:
      memory: 128Mi
      cpu: 250m

# Web UI 활성화
ui:
  enabled: true
```

> **저장소 선택**: `raft`를 사용한다. `file` 대비 스냅샷 백업/복구가 가능하다.

### Step 3: 설치 실행

```bash
kubectl create namespace openbao

helm install openbao openbao/openbao \
  -n openbao \
  -f /opt/k3s-lab/openbao-values.yaml
```

확인:

```bash
kubectl get pods -n openbao
```

```
NAME                                    READY   STATUS    RESTARTS   AGE
openbao-0                               0/1     Running   0          30s
openbao-agent-injector-xxxxxxxxx-xxxxx  1/1     Running   0          30s
```

> `openbao-0`이 `0/1`인 것은 정상 — 아직 초기화/Unseal 전이다.

---

## Part 2: 초기화 및 Unseal

### Step 4: 초기화 (최초 1회)

```bash
# 파드 내부에서 실행
kubectl exec -n openbao openbao-0 -- bao operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json > /opt/k3s-lab/openbao-init.json
```

> **key-shares=1, key-threshold=1**: 싱글 노드 내부망 환경이므로 간소화.
> 프로덕션에서는 `-key-shares=5 -key-threshold=3` (5개 키 중 3개로 Unseal) 권장.

출력 파일에서 키 확인:

```bash
cat /opt/k3s-lab/openbao-init.json
```

```json
{
  "unseal_keys_b64": ["xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx="],
  "root_token": "s.xxxxxxxxxxxxxxxxxxxxxxxx"
}
```

> **반드시 안전한 곳에 백업**: unseal key와 root token을 분실하면 데이터를 복구할 수 없다.
> 비밀번호 관리자, 암호화된 USB, 또는 인쇄 후 금고 보관.

### Step 5: Unseal

```bash
# unseal key 추출
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /opt/k3s-lab/openbao-init.json)

# Unseal 실행
kubectl exec -n openbao openbao-0 -- bao operator unseal "$UNSEAL_KEY"
```

확인:

```bash
kubectl exec -n openbao openbao-0 -- bao status
```

```
Sealed          false    ← false면 정상
```

파드 상태도 확인:

```bash
kubectl get pods -n openbao
```

```
openbao-0    1/1     Running    ← 1/1로 변경됨
```

### Step 6: 자동 Unseal 설정 (파드 재시작 대비)

OpenBao 파드가 재시작되면 다시 Sealed 상태가 된다. 자동 Unseal을 위해 K8s Secret + CronJob을 설정한다.

#### 6-1. Unseal Key를 K8s Secret으로 저장

```bash
UNSEAL_KEY=$(jq -r '.unseal_keys_b64[0]' /opt/k3s-lab/openbao-init.json)

kubectl create secret generic openbao-unseal \
  -n openbao \
  --from-literal=unseal-key="$UNSEAL_KEY"
```

#### 6-2. 자동 Unseal CronJob 생성

1분마다 sealed 상태를 확인하고, sealed면 자동으로 unseal한다:

```yaml
# /opt/k3s-lab/openbao-auto-unseal.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: openbao-auto-unseal
  namespace: openbao
spec:
  schedule: "* * * * *"  # 매 1분
  successfulJobsHistoryLimit: 1
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          serviceAccountName: openbao
          containers:
          - name: unseal
            image: quay.io/openbao/openbao:2.5.2
            env:
            - name: BAO_ADDR
              value: "http://openbao.openbao.svc:8200"
            - name: UNSEAL_KEY
              valueFrom:
                secretKeyRef:
                  name: openbao-unseal
                  key: unseal-key
            command:
            - /bin/sh
            - -c
            - |
              STATUS=$(bao status -format=json 2>/dev/null || echo '{"sealed":true}')
              SEALED=$(echo "$STATUS" | grep -o '"sealed":[a-z]*' | cut -d: -f2)
              if [ "$SEALED" = "true" ]; then
                echo "OpenBao is sealed. Unsealing..."
                bao operator unseal "$UNSEAL_KEY"
                echo "Unseal complete."
              else
                echo "OpenBao is already unsealed."
              fi
          restartPolicy: OnFailure
```

```bash
kubectl apply -f /opt/k3s-lab/openbao-auto-unseal.yaml
```

> **보안 참고**: Unseal Key가 K8s Secret에 저장되므로, K3s etcd 암호화를 활성화하는 것을 권장한다.
> 클라우드 환경이라면 AWS KMS / GCP Cloud KMS Transit auto-unseal이 더 안전하다.

---

## Part 3: OpenBao 기본 설정

### Step 7: CLI 접근 설정

#### 방법 A: 파드 내부에서 직접 실행

```bash
# root token 확인
ROOT_TOKEN=$(jq -r '.root_token' /opt/k3s-lab/openbao-init.json)

# 파드 내부 쉘 접속
kubectl exec -it -n openbao openbao-0 -- /bin/sh

# 파드 내부에서
export BAO_ADDR="http://127.0.0.1:8200"
export BAO_TOKEN="<root-token>"
```

#### 방법 B: 로컬에서 port-forward

```bash
# 터미널 1: port-forward
kubectl port-forward svc/openbao -n openbao 8200:8200

# 터미널 2: CLI 사용
export BAO_ADDR="http://127.0.0.1:8200"
export BAO_TOKEN="<root-token>"
bao status
```

#### 방법 C: bao CLI 설치 (개발자 PC)

```bash
# macOS
brew install openbao

# Linux (바이너리)
# https://openbao.org/downloads/ 에서 다운로드

# 확인
bao version
```

### Step 8: Web UI 접근 (선택)

HTTPRoute를 추가해서 브라우저로 접근할 수 있다:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: openbao
  namespace: openbao
spec:
  parentRefs:
  - name: eg
    namespace: default
  hostnames:
  - "openbao.local"
  rules:
  - backendRefs:
    - name: openbao
      port: 8200
```

```bash
kubectl apply -f openbao-httproute.yaml
```

PC의 `/etc/hosts`에 추가:

```
192.168.70.142  openbao.local
```

브라우저에서 `http://openbao.local:30080` 접속 → root token으로 로그인.

---

## Part 4: Kubernetes 인증 설정

### Step 9: K8s Auth Method 활성화

파드가 OpenBao에 인증할 수 있도록 Kubernetes Auth Method를 설정한다.

```bash
# 파드 내부에서 실행 (Step 7-A 방법)
kubectl exec -it -n openbao openbao-0 -- /bin/sh

export BAO_ADDR="http://127.0.0.1:8200"
export BAO_TOKEN="<root-token>"

# K8s Auth 활성화
bao auth enable kubernetes

# K8s Auth 설정 (파드 내부에서 실행하면 자동 감지됨)
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
```

확인:

```bash
bao auth list
```

```
Path              Type
----              ----
kubernetes/       kubernetes
token/            token
```

---

## Part 5: KV 시크릿 관리 (DB 비밀번호 등)

### Step 10: KV Secrets Engine 활성화

```bash
# KV v2 활성화
bao secrets enable -path=secret -version=2 kv
```

### Step 11: 시크릿 저장

```bash
# dev 환경 DB 시크릿
bao kv put secret/insideinfo/dev/api-database \
  spring.datasource.url="jdbc:mysql://192.168.70.142:13306/INSIDEDB?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Seoul&characterEncoding=UTF-8" \
  spring.datasource.username="INSIDE" \
  spring.datasource.password="1qaz@WSX3edc"

# prod 환경 DB 시크릿
bao kv put secret/insideinfo/prod/api-database \
  spring.datasource.url="jdbc:mysql://192.168.70.142:3306/INSIDEDB?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Seoul&characterEncoding=UTF-8" \
  spring.datasource.username="INSIDE" \
  spring.datasource.password="1qaz@WSX3edc"
```

확인:

```bash
bao kv get secret/insideinfo/dev/api-database
```

### Step 12: 접근 정책 생성

```bash
# insideinfo-api dev 정책
bao policy write insideinfo-api-dev - <<EOF
path "secret/data/insideinfo/dev/api-database" {
  capabilities = ["read", "list"]
}
EOF

# insideinfo-api prod 정책
bao policy write insideinfo-api-prod - <<EOF
path "secret/data/insideinfo/prod/api-database" {
  capabilities = ["read", "list"]
}
EOF
```

### Step 13: K8s Auth Role 생성

```bash
# dev용 ServiceAccount 생성 (insideinfo 네임스페이스에)
kubectl create serviceaccount openbao-auth-api-dev -n insideinfo

# OpenBao Role 바인딩
bao write auth/kubernetes/role/insideinfo-api-dev \
  bound_service_account_names=openbao-auth-api-dev \
  bound_service_account_namespaces=insideinfo \
  policies=insideinfo-api-dev \
  ttl=1h \
  max_ttl=24h

# prod도 동일하게
kubectl create serviceaccount openbao-auth-api-prod -n insideinfo

bao write auth/kubernetes/role/insideinfo-api-prod \
  bound_service_account_names=openbao-auth-api-prod \
  bound_service_account_namespaces=insideinfo \
  policies=insideinfo-api-prod \
  ttl=1h \
  max_ttl=24h
```

---

## Part 6: External Secrets Operator (ESO) 연동

ESO는 OpenBao의 시크릿을 자동으로 K8s Secret으로 변환해주는 Operator이다.

> **왜 ESO인가?** OpenBao 자체 Secrets Operator(BSO)는 2026-02에 archived 되었고,
> 공식적으로 ESO 사용을 권장한다. ESO는 Vault provider로 OpenBao와 호환된다.

### Step 14: ESO 설치

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

helm install external-secrets external-secrets/external-secrets \
  -n external-secrets \
  --create-namespace \
  --wait
```

확인:

```bash
kubectl get pods -n external-secrets
```

### Step 15: SecretStore 생성

```yaml
# /opt/k3s-lab/eso-secretstore-dev.yaml
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: openbao
  namespace: insideinfo
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc:8200"
      path: "secret"
      version: "v2"
      auth:
        kubernetes:
          mountPath: "kubernetes"
          role: "insideinfo-api-dev"
          serviceAccountRef:
            name: "openbao-auth-api-dev"
```

```bash
kubectl apply -f /opt/k3s-lab/eso-secretstore-dev.yaml
```

확인:

```bash
kubectl get secretstore -n insideinfo
```

`STATUS`가 `Valid`면 정상.

### Step 16: ExternalSecret 생성

OpenBao의 시크릿을 K8s Secret으로 자동 동기화한다.

#### 방법 A: application-secret.yml 전체를 하나의 키로

현재 Spring Boot가 `application-secret.yml` 파일을 마운트해서 읽는 구조이므로, 이 방식이 기존과 호환된다.

```bash
# 먼저 OpenBao에 application-secret.yml 내용을 통째로 저장
bao kv put secret/insideinfo/dev/api-config \
  application-secret.yml="spring:
  datasource:
    url: jdbc:mysql://192.168.70.142:13306/INSIDEDB?useSSL=false&allowPublicKeyRetrieval=true&serverTimezone=Asia/Seoul&characterEncoding=UTF-8
    username: INSIDE
    password: 1qaz@WSX3edc"
```

```yaml
# eso-externalsecret-api-dev.yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: insideinfo-api-dev-config
  namespace: insideinfo
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: SecretStore
  target:
    name: insideinfo-api-dev-config   # 기존 Secret 이름과 동일
    creationPolicy: Owner
  data:
  - secretKey: application-secret.yml
    remoteRef:
      key: insideinfo/dev/api-config
      property: application-secret.yml
```

```bash
kubectl apply -f eso-externalsecret-api-dev.yaml
```

확인:

```bash
# ExternalSecret 상태
kubectl get externalsecret -n insideinfo

# 생성된 K8s Secret 확인
kubectl get secret insideinfo-api-dev-config -n insideinfo

# 내용 확인
kubectl get secret insideinfo-api-dev-config -n insideinfo \
  -o jsonpath='{.data.application-secret\.yml}' | base64 -d
```

#### 방법 B: 개별 키로 분리 (향후 Spring Cloud Config 전환 시)

```yaml
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: insideinfo-api-dev-db
  namespace: insideinfo
spec:
  refreshInterval: 1h
  secretStoreRef:
    name: openbao
    kind: SecretStore
  target:
    name: insideinfo-api-dev-db
    creationPolicy: Owner
  data:
  - secretKey: SPRING_DATASOURCE_URL
    remoteRef:
      key: insideinfo/dev/api-database
      property: spring.datasource.url
  - secretKey: SPRING_DATASOURCE_USERNAME
    remoteRef:
      key: insideinfo/dev/api-database
      property: spring.datasource.username
  - secretKey: SPRING_DATASOURCE_PASSWORD
    remoteRef:
      key: insideinfo/dev/api-database
      property: spring.datasource.password
```

### Step 17: Helm 템플릿에서 기존 Secret 제거

ESO가 Secret을 생성하므로, Helm Chart의 `secret.yaml` 템플릿을 비활성화한다.

`apps/insideinfo-api/helm/values/dev/inside-api-values.yaml`에서:

```yaml
# 아래 블록 삭제 (ESO가 대신 생성)
secret:
  data:
    config:
      application-secret.yml: |
        ...
```

`apps/insideinfo-api/helm/templates/secret.yaml`은 `{{- if .Values.secret }}` 조건이 있으므로 values에서 secret을 제거하면 자동으로 비활성화된다.

> **주의**: ExternalSecret의 `target.name`이 기존 Secret 이름(`insideinfo-api-dev-config`)과 동일해야 파드의 volumeMount가 그대로 동작한다.

### Step 18: gitops 레포에 ExternalSecret 추가

ExternalSecret 매니페스트를 Helm 차트에 추가한다.

`apps/insideinfo-api/helm/templates/external-secret.yaml`:

```yaml
{{- if .Values.externalSecret }}
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: {{ include "insideinfo-api.fullname" . }}-config
  labels:
    {{- include "insideinfo-api.labels" . | nindent 4 }}
spec:
  refreshInterval: {{ .Values.externalSecret.refreshInterval | default "1h" }}
  secretStoreRef:
    name: {{ .Values.externalSecret.storeName }}
    kind: SecretStore
  target:
    name: {{ include "insideinfo-api.fullname" . }}-config
    creationPolicy: Owner
  data:
  {{- range .Values.externalSecret.data }}
  - secretKey: {{ .secretKey }}
    remoteRef:
      key: {{ .remoteKey }}
      property: {{ .remoteProperty }}
  {{- end }}
{{- end }}
```

values에 추가:

```yaml
externalSecret:
  refreshInterval: "1h"
  storeName: openbao
  data:
  - secretKey: application-secret.yml
    remoteKey: insideinfo/dev/api-config
    remoteProperty: application-secret.yml
```

---

## Part 7: PKI 인증서 관리 (cert-manager 연동)

### Step 19: PKI Engine 설정

OpenBao를 내부 CA로 구성한다.

```bash
kubectl exec -it -n openbao openbao-0 -- /bin/sh

export BAO_ADDR="http://127.0.0.1:8200"
export BAO_TOKEN="<root-token>"

# 1. Root CA 용 PKI 활성화
bao secrets enable -path=pki pki
bao secrets tune -max-lease-ttl=87600h pki   # 10년

# 2. Root CA 인증서 생성
bao write -field=certificate pki/root/generate/internal \
  common_name="InsideInfo Root CA" \
  ttl=87600h > /tmp/root_ca.crt

# 3. CA URL 설정
bao write pki/config/urls \
  issuing_certificates="http://openbao.openbao.svc:8200/v1/pki/ca" \
  crl_distribution_points="http://openbao.openbao.svc:8200/v1/pki/crl"

# 4. Intermediate CA 용 PKI 활성화
bao secrets enable -path=pki_int pki
bao secrets tune -max-lease-ttl=43800h pki_int   # 5년

# 5. Intermediate CA CSR 생성
bao write -format=json pki_int/intermediate/generate/internal \
  common_name="InsideInfo Intermediate CA" \
  | jq -r '.data.csr' > /tmp/pki_int.csr

# 6. Root CA로 Intermediate 서명
bao write -format=json pki/root/sign-intermediate \
  csr=@/tmp/pki_int.csr \
  format=pem_bundle \
  ttl=43800h \
  | jq -r '.data.certificate' > /tmp/signed_int.crt

# 7. Intermediate에 서명된 인증서 등록
bao write pki_int/intermediate/set-signed certificate=@/tmp/signed_int.crt

# 8. 인증서 발급 Role 생성
bao write pki_int/roles/server-cert \
  allowed_domains="insideinfo,insideinfo.co.kr,insideinfo.api,svc.cluster.local" \
  allow_subdomains=true \
  allow_bare_domains=true \
  max_ttl=720h   # 30일
```

확인:

```bash
bao read pki_int/roles/server-cert
```

### Step 20: cert-manager 용 정책 및 Role 생성

```bash
# cert-manager가 인증서를 발급할 수 있는 정책
bao policy write cert-manager - <<EOF
path "pki_int/sign/server-cert" {
  capabilities = ["create", "update"]
}
path "pki_int/issuer/+/sign/server-cert" {
  capabilities = ["create", "update"]
}
EOF

# cert-manager ServiceAccount에 대한 K8s Auth Role
bao write auth/kubernetes/role/cert-manager \
  bound_service_account_names=cert-manager \
  bound_service_account_namespaces=cert-manager \
  policies=cert-manager \
  ttl=1h
```

### Step 21: cert-manager ClusterIssuer 생성 (OpenBao 연동)

cert-manager의 Vault Issuer가 OpenBao와 호환된다.

```yaml
# /opt/k3s-lab/openbao-clusterissuer.yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: openbao-issuer
spec:
  vault:
    path: pki_int/sign/server-cert
    server: http://openbao.openbao.svc:8200
    auth:
      kubernetes:
        role: cert-manager
        mountPath: /v1/auth/kubernetes
        serviceAccountRef:
          name: cert-manager
```

```bash
kubectl apply -f /opt/k3s-lab/openbao-clusterissuer.yaml
```

확인:

```bash
kubectl get clusterissuer openbao-issuer
```

`READY`가 `True`면 정상.

### Step 22: 인증서 발급

```yaml
# /opt/k3s-lab/openbao-certificate.yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insideinfo-tls
  namespace: default   # Gateway가 있는 네임스페이스
spec:
  secretName: insideinfo-tls-secret
  duration: 720h       # 30일
  renewBefore: 168h    # 만료 7일 전 자동 갱신
  issuerRef:
    name: openbao-issuer
    kind: ClusterIssuer
  dnsNames:
  - dev.insideinfo
  - dev.insideinfo.api
  - prod.insideinfo
  - prod.insideinfo.api
```

```bash
kubectl apply -f /opt/k3s-lab/openbao-certificate.yaml
```

확인:

```bash
# 인증서 상태
kubectl get certificate insideinfo-tls -n default

# 발급된 Secret
kubectl get secret insideinfo-tls-secret -n default
```

### Step 23: Gateway에 HTTPS 적용

06 가이드의 Part 2 A-3과 동일한 방식:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    allowedRoutes:
      namespaces:
        from: All
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: insideinfo-tls-secret
    allowedRoutes:
      namespaces:
        from: All
```

NAT 환경 NodePort 추가:

```bash
ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=eg \
  -o jsonpath='{.items[0].metadata.name}')

kubectl patch svc "$ENVOY_SVC" -n envoy-gateway-system --type merge \
  -p '{"spec":{"ports":[
    {"name":"http","port":80,"targetPort":80,"nodePort":30080,"protocol":"TCP"},
    {"name":"https","port":443,"targetPort":443,"nodePort":30443,"protocol":"TCP"}
  ]}}'
```

---

## Part 8: 백업

### Step 24: Raft 스냅샷 백업

#### 수동 백업

```bash
kubectl exec -n openbao openbao-0 -- \
  bao operator raft snapshot save /tmp/backup.snap

kubectl cp openbao/openbao-0:/tmp/backup.snap \
  /opt/k3s-lab/openbao-backup-$(date +%Y%m%d).snap
```

#### 자동 백업 (일일 CronJob)

```yaml
# /opt/k3s-lab/openbao-backup-cronjob.yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: openbao-backup
  namespace: openbao
spec:
  schedule: "0 2 * * *"   # 매일 02:00
  successfulJobsHistoryLimit: 3
  failedJobsHistoryLimit: 3
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: quay.io/openbao/openbao:2.5.2
            env:
            - name: BAO_ADDR
              value: "http://openbao.openbao.svc:8200"
            - name: BAO_TOKEN
              valueFrom:
                secretKeyRef:
                  name: openbao-root-token
                  key: token
            command:
            - /bin/sh
            - -c
            - |
              FILENAME="snapshot-$(date +%Y%m%d-%H%M).snap"
              bao operator raft snapshot save "/backup/$FILENAME"
              echo "Backup saved: $FILENAME"
              # 7일 이상된 백업 삭제
              find /backup -name "*.snap" -mtime +7 -delete
            volumeMounts:
            - name: backup-storage
              mountPath: /backup
          volumes:
          - name: backup-storage
            hostPath:
              path: /opt/k3s-lab/openbao-backups
              type: DirectoryOrCreate
          restartPolicy: OnFailure
```

root token Secret 생성:

```bash
ROOT_TOKEN=$(jq -r '.root_token' /opt/k3s-lab/openbao-init.json)
kubectl create secret generic openbao-root-token \
  -n openbao \
  --from-literal=token="$ROOT_TOKEN"
```

```bash
kubectl apply -f /opt/k3s-lab/openbao-backup-cronjob.yaml
```

#### 복구

```bash
kubectl cp /opt/k3s-lab/openbao-backup-20260416.snap openbao/openbao-0:/tmp/restore.snap

kubectl exec -n openbao openbao-0 -- \
  bao operator raft snapshot restore /tmp/restore.snap
```

---

## Part 9: Sealed Secrets 제거

OpenBao + ESO가 안정적으로 동작하는 것을 확인한 뒤:

```bash
# Sealed Secrets 컨트롤러 제거
helm uninstall sealed-secrets -n kube-system

# kubeseal CLI 제거
sudo rm /usr/local/bin/kubeseal
```

기존 self-signed ClusterIssuer도 OpenBao Issuer로 대체한 경우:

```bash
kubectl delete clusterissuer selfsigned-issuer
```

`k3s-apps.sh`에서 [8] Sealed Secrets 섹션 주석 처리.

---

## k3s-apps.sh 수정 요약

OpenBao 방식을 적용하면 `k3s-apps.sh`에 아래 변경이 필요하다:

| 섹션 | 변경 |
|------|------|
| [8] Sealed Secrets | **삭제 또는 주석 처리** |
| [8-1] kubeseal CLI | **삭제 또는 주석 처리** |
| 신규: OpenBao 설치 | Helm install + init + unseal + 기본 설정 |
| 신규: ESO 설치 | Helm install |
| [4-1] ClusterIssuer | self-signed → openbao-issuer로 교체 (선택) |

---

## 일상 운영 명령어 모음

### 시크릿 조회

```bash
# 시크릿 목록
bao kv list secret/insideinfo/dev/

# 시크릿 조회
bao kv get secret/insideinfo/dev/api-database

# 특정 필드만
bao kv get -field=spring.datasource.password secret/insideinfo/dev/api-database
```

### 시크릿 수정

```bash
# 비밀번호 변경
bao kv patch secret/insideinfo/dev/api-database \
  spring.datasource.password="새비밀번호"

# ESO가 refreshInterval(1h) 후 자동 반영
# 즉시 반영하려면:
kubectl annotate externalsecret insideinfo-api-dev-config \
  -n insideinfo \
  force-sync=$(date +%s) --overwrite
```

### 인증서 수동 발급 (테스트용)

```bash
bao write pki_int/issue/server-cert \
  common_name="test.insideinfo" \
  ttl=24h
```

### 상태 확인

```bash
# OpenBao 상태
bao status

# Auth 방법 목록
bao auth list

# Secrets Engine 목록
bao secrets list

# 정책 목록
bao policy list

# Raft 피어 목록
bao operator raft list-peers
```

### 토큰 관리

```bash
# 제한된 권한의 토큰 생성 (관리자에게 발급)
bao token create -policy=insideinfo-api-dev -ttl=8h

# 토큰 폐기
bao token revoke <token>
```

---

## 트러블슈팅

### OpenBao 파드가 0/1 Running

Unsealed 되지 않은 상태. Step 5 참고.

```bash
kubectl exec -n openbao openbao-0 -- bao status
# Sealed: true → unseal 필요
```

### ESO SecretStore가 Invalid

```bash
kubectl describe secretstore openbao -n insideinfo
```

흔한 원인:
- OpenBao 주소 오류 (`http://openbao.openbao.svc:8200` 확인)
- ServiceAccount가 없거나 K8s Auth Role과 불일치
- OpenBao가 sealed 상태

### cert-manager Issuer가 Not Ready

```bash
kubectl describe clusterissuer openbao-issuer
```

흔한 원인:
- cert-manager ServiceAccount에 대한 K8s Auth Role 미생성
- PKI Engine 미활성화 또는 Role 이름 오타
- OpenBao 네트워크 접근 불가

### ExternalSecret이 SecretSyncedError

```bash
kubectl describe externalsecret -n insideinfo
```

흔한 원인:
- KV path 오류 (KV v2는 `secret/data/...`이지만 ExternalSecret에서는 `data/` 없이 기술)
- 정책에 read 권한 없음
- 시크릿 키(property) 이름 오타

### 파드 재시작 후 모든 시크릿 접근 불가

OpenBao가 sealed 상태. 자동 Unseal CronJob(Step 6-2)이 정상 동작하는지 확인:

```bash
kubectl get cronjob openbao-auto-unseal -n openbao
kubectl get jobs -n openbao --sort-by=.metadata.creationTimestamp | tail -5
```

---

## 설정값 참조

| 항목 | 값 |
|------|-----|
| OpenBao 버전 | v2.5.2 |
| Helm Chart | openbao/openbao |
| OpenBao namespace | `openbao` |
| OpenBao 내부 주소 | `http://openbao.openbao.svc:8200` |
| Web UI (HTTPRoute) | `http://openbao.local:30080` |
| KV Engine path | `secret/` (v2) |
| PKI Root path | `pki/` |
| PKI Intermediate path | `pki_int/` |
| PKI Role | `server-cert` |
| K8s Auth path | `auth/kubernetes/` |
| ESO namespace | `external-secrets` |
| 초기화 키 파일 | `/opt/k3s-lab/openbao-init.json` (안전 보관!) |
| 백업 위치 | `/opt/k3s-lab/openbao-backups/` |
| HTTPS NodePort | `30443` |
