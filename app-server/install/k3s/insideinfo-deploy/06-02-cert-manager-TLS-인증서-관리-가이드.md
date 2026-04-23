# cert-manager TLS 인증서 관리 가이드

cert-manager를 사용하여 K8s 클러스터의 TLS 인증서를 자동 발급/갱신하는 가이드.
SOPS(시크릿 암호화)와는 역할이 다르다 — SOPS는 DB 비밀번호 등 시크릿, cert-manager는 TLS 인증서.

---

## 배경

| 현재 상태 | 설명 |
|-----------|------|
| cert-manager 설치됨 | `cert-manager` 네임스페이스 |
| ClusterIssuer | `selfsigned-issuer` (자체서명) 하나만 존재 |
| 실제 인증서 | 미발급 (Certificate 리소스 0개) |
| 서비스 접근 | 모두 HTTP only |

### SOPS와의 역할 구분

| 상황 | 도구 |
|------|------|
| TLS 인증서 자동 발급/갱신 | **cert-manager** (SOPS로 대체 불가) |
| DB 비밀번호, API 키 등 시크릿 | **SOPS** (06-01 가이드 참고) |
| 외부에서 받은 인증서를 수동 등록 | SOPS로 암호화해서 Git 저장 가능 |
| 인증서 발급에 필요한 DNS API 키 | SOPS로 암호화 |

---

## 전제 조건

| 항목 | 상태 |
|------|------|
| 01-배포-가이드.md | 완료 |
| cert-manager | 설치됨 (k3s-apps.sh [4]) |
| Envoy Gateway | 설치됨 (Gateway `eg`, default 네임스페이스) |

---

## 시나리오별 설정

| 시나리오 | 설정 | 비고 |
|----------|------|------|
| **내부망 전용 (현재)** | self-signed issuer → 그대로 유지 | 추가 작업 없음 |
| **내부망 + HTTPS 필요** | self-signed CA issuer 추가 | 아래 A 참고 |
| **외부 공개** | Let's Encrypt issuer 추가 | 아래 B 참고 |

---

## A. 내부망 HTTPS (self-signed CA)

내부에서만 사용하지만 HTTPS가 필요한 경우 (ex. 브라우저 보안 경고 최소화).

### A-1. 자체 CA 인증서 생성

```yaml
# self-signed로 CA 인증서를 먼저 발급
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
---
# CA용 인증서 발급
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insideinfo-ca
  namespace: cert-manager
spec:
  isCA: true
  commonName: insideinfo-ca
  secretName: insideinfo-ca-secret
  duration: 87600h  # 10년
  issuerRef:
    name: selfsigned-issuer
    kind: ClusterIssuer
---
# CA를 사용하는 ClusterIssuer
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: insideinfo-ca-issuer
spec:
  ca:
    secretName: insideinfo-ca-secret
```

```bash
kubectl apply -f ca-issuer.yaml
```

### A-2. 서비스용 인증서 발급

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insideinfo-tls
  namespace: default  # Gateway가 있는 네임스페이스
spec:
  secretName: insideinfo-tls-secret
  duration: 8760h  # 1년
  renewBefore: 720h  # 만료 30일 전 자동 갱신
  issuerRef:
    name: insideinfo-ca-issuer
    kind: ClusterIssuer
  dnsNames:
    - dev.insideinfo
    - dev.insideinfo.api
    - prod.insideinfo
    - prod.insideinfo.api
```

```bash
kubectl apply -f certificate.yaml
```

확인:

```bash
kubectl get certificate -A
kubectl get secret insideinfo-tls-secret
```

### A-3. Gateway에 HTTPS listener 추가

기존 `k3s-apps.sh`의 Gateway 설정에 TLS listener를 추가:

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
  # HTTPS listener 추가
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

NAT 환경이면 NodePort도 추가:

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

방화벽 포트 오픈: `30443/tcp`

> **참고**: 자체서명 CA이므로 브라우저에서 인증서 경고가 뜬다. 내부 PC에 CA 인증서를 신뢰 등록하면 경고가 사라진다:
>
> ```bash
> # CA 인증서 추출
> kubectl get secret insideinfo-ca-secret -n cert-manager -o jsonpath='{.data.ca\.crt}' | base64 -d > insideinfo-ca.crt
> # PC에서 이 파일을 신뢰 인증서로 등록
> ```

---

## B. 외부 공개 시 Let's Encrypt

실제 도메인(ex. `insideinfo.co.kr`)으로 외부에 공개할 때.

### 전제 조건

- 외부 IP 확보 완료
- 도메인 DNS가 외부 IP를 가리킴
- 방화벽에서 80, 443 포트 오픈

### B-1. Let's Encrypt ClusterIssuer 생성

```yaml
# staging (테스트용, 발급 제한 없음)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-staging
spec:
  acme:
    server: https://acme-staging-v02.api.letsencrypt.org/directory
    email: qwep0224@insideinfo.co.kr
    privateKeySecretRef:
      name: letsencrypt-staging-key
    solvers:
    - http01:
        gatewayHTTPRoute:
          parentRefs:
          - name: eg
            namespace: default
---
# production (실제 인증서)
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: qwep0224@insideinfo.co.kr
    privateKeySecretRef:
      name: letsencrypt-prod-key
    solvers:
    - http01:
        gatewayHTTPRoute:
          parentRefs:
          - name: eg
            namespace: default
```

> Gateway API 환경이므로 `gatewayHTTPRoute` solver를 사용한다 (Ingress가 아님).

### B-2. 인증서 발급

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insideinfo-tls-prod
  namespace: default
spec:
  secretName: insideinfo-tls-prod-secret
  duration: 2160h  # 90일 (Let's Encrypt 기본)
  renewBefore: 360h  # 만료 15일 전 자동 갱신
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - insideinfo.co.kr
    - api.insideinfo.co.kr
```

### B-3. Gateway 설정

A-3과 동일하되 `certificateRefs`를 `insideinfo-tls-prod-secret`으로 변경.

### B-4. HTTP → HTTPS 리다이렉트 (선택)

Envoy Gateway에서 HTTPRoute로 리다이렉트 설정:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: default
spec:
  parentRefs:
  - name: eg
    namespace: default
    sectionName: http
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
```

---

## 트러블슈팅

### cert-manager 인증서 발급 실패

```bash
# Certificate 상태 확인
kubectl describe certificate insideinfo-tls -n default

# CertificateRequest 확인
kubectl get certificaterequest -A

# Challenge 확인 (Let's Encrypt ACME)
kubectl get challenge -A
```

흔한 원인:
- Let's Encrypt: 외부에서 80 포트 접근 불가 (방화벽)
- Let's Encrypt: DNS가 외부 IP를 가리키지 않음
- Self-signed: ClusterIssuer가 없거나 이름 오타

### 인증서 갱신 확인

```bash
# 만료일 확인
kubectl get certificate -A -o wide

# 인증서 상세
kubectl describe certificate insideinfo-tls -n default
```

cert-manager는 `renewBefore` 설정에 따라 만료 전 자동 갱신한다. 수동 갱신이 필요하면:

```bash
kubectl delete certificaterequest -n default --all
# cert-manager가 자동으로 새 CertificateRequest를 생성하여 갱신
```

---

## 설정값 참조

| 항목 | 값 |
|------|-----|
| cert-manager namespace | `cert-manager` |
| ClusterIssuer (self-signed) | `selfsigned-issuer` |
| ClusterIssuer (내부 CA) | `insideinfo-ca-issuer` |
| ClusterIssuer (Let's Encrypt staging) | `letsencrypt-staging` |
| ClusterIssuer (Let's Encrypt prod) | `letsencrypt-prod` |
| Gateway 이름 | `eg` (default 네임스페이스) |
| HTTPS NodePort | `30443` |
