# TLS 인증서 적용 가이드

`www.insideinfo.co.kr` 도메인에 HTTPS를 적용하는 가이드.  
인증서 종류에 따라 3가지 시나리오로 구분하여 설명한다.

---

## 전제 조건

| 항목 | 상태 |
|------|------|
| 01-배포-가이드.md | 완료 |
| cert-manager | 설치됨 (`cert-manager` 네임스페이스) |
| ClusterIssuer | `selfsigned-issuer` 존재 |
| Envoy Gateway | 설치됨 (`eg`, `default` 네임스페이스) |
| Gateway 리스너 | HTTP 80만 존재 (HTTPS 없음) |
| 환경 | NAT 사용 (`USE_NAT=true`), NodePort 30080 |

---

## 시나리오 선택

| 시나리오 | 언제 사용 | 비고 |
|----------|----------|------|
| **A. 외부 인증서** | 기관(가비아, DigiCert 등)에서 구매한 `.crt`/`.key` 파일 보유 시 | cert-manager 불필요 |
| **B. 자체 CA 인증서** | 내부 CA에서 발급한 인증서 파일 보유 시, 또는 cert-manager로 내부 CA 구성 시 | 브라우저 경고 발생 (CA 신뢰 등록 필요) |
| **C. Let's Encrypt** | 공인 인증서가 필요하고, 외부에서 80/443 포트 접근 가능 시 | 무료, 90일마다 자동 갱신 |

---

## 공통 — NodePort 30443 추가 (모든 시나리오 필수)

HTTPS 트래픽(443)을 클러스터 외부에서 받기 위해 NodePort를 추가한다.

```bash
# Envoy 서비스 이름 확인
ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system \
  -l gateway.envoyproxy.io/owning-gateway-name=eg \
  -o jsonpath='{.items[0].metadata.name}')

echo "Envoy 서비스: $ENVOY_SVC"

# 30443 NodePort 추가 (기존 30080 유지)
kubectl patch svc "$ENVOY_SVC" -n envoy-gateway-system --type merge \
  -p '{"spec":{"ports":[
    {"name":"http","port":80,"targetPort":80,"nodePort":30080,"protocol":"TCP"},
    {"name":"https","port":443,"targetPort":443,"nodePort":30443,"protocol":"TCP"}
  ]}}'
```

공유기/방화벽에서 포트 포워딩 추가:

```
외부 443 → 서버 내부 IP:30443
```

방화벽 오픈 (서버에서):

```bash
firewall-cmd --permanent --add-port=30443/tcp
firewall-cmd --reload
```

---

## A. 외부 인증서 (구매/발급 받은 `.crt` / `.key` 파일)

인증서 파일을 직접 Kubernetes Secret으로 등록하고 Gateway에 연결하는 방식.  
cert-manager가 관리하지 않으므로 만료일을 직접 추적해야 한다.

### A-1. 인증서 파일 확인

보유한 파일:

| 파일 | 설명 |
|------|------|
| `cert.crt` (또는 `fullchain.crt`) | 서버 인증서 + 체인 인증서 포함 파일 |
| `cert.key` | 개인 키 |

> 중간 인증서(체인)가 별도 파일로 있는 경우 하나로 합친다:
> ```bash
> cat cert.crt chain.crt > fullchain.crt
> ```

### A-2. TLS Secret 생성

```bash
kubectl create secret tls insideinfo-web-tls-secret \
  --cert=fullchain.crt \
  --key=cert.key \
  -n default

# 확인
kubectl get secret insideinfo-web-tls-secret -n default
```

### A-3. Gateway에 HTTPS 리스너 추가

```bash
kubectl apply -f - <<EOF
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
      - name: insideinfo-web-tls-secret
    allowedRoutes:
      namespaces:
        from: All
EOF
```

Gateway 상태 확인:

```bash
kubectl get gateway eg -o wide
kubectl describe gateway eg
```

`READY: True` 확인.

### A-4. gitops 수정

**`insideinfo-gitops/apps/insideinfo-web/helm/templates/ingress.yaml`** — `sectionName` 지원 추가:

```yaml
{{- if .Values.httproute.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "insideinfo-web.fullname" . }}
  labels:
    {{- include "insideinfo-web.labels" . | nindent 4 }}
spec:
  parentRefs:
  - name: {{ .Values.httproute.gatewayName }}
    namespace: {{ .Values.httproute.gatewayNamespace }}
    {{- if .Values.httproute.sectionName }}
    sectionName: {{ .Values.httproute.sectionName }}
    {{- end }}
  hostnames:
    {{- range .Values.httproute.hostnames }}
  - {{ . | quote }}
    {{- end }}
  rules:
  - backendRefs:
    - name: {{ include "insideinfo-web.fullname" . }}
      port: {{ .Values.service.port }}
{{- end }}
```

**`insideinfo-gitops/apps/insideinfo-web/helm/values/prod/inside-web-values.yaml`** — hostname 및 sectionName 추가:

```yaml
httproute:
  enabled: true
  gatewayName: eg
  gatewayNamespace: default
  sectionName: https            # HTTPS 리스너에만 연결
  hostnames:
  - prod.insideinfo
  - www.insideinfo.co.kr       # 실제 도메인 추가
  - insideinfo.co.kr           # apex 도메인 (선택)
```

gitops push 후 ArgoCD에서 prod 수동 Sync.

### A-5. HTTP → HTTPS 리다이렉트

```bash
kubectl apply -f - <<EOF
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
  hostnames:
  - www.insideinfo.co.kr
  - insideinfo.co.kr
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
EOF
```

### A-6. 인증서 갱신 시

외부 인증서는 cert-manager가 관리하지 않으므로 만료 전 수동 갱신:

```bash
# 새 파일로 Secret 교체
kubectl create secret tls insideinfo-web-tls-secret \
  --cert=new-fullchain.crt \
  --key=new-cert.key \
  -n default \
  --dry-run=client -o yaml | kubectl apply -f -
```

> **주의**: 만료일을 캘린더에 등록해 두는 것을 권장한다.  
> 만료일 확인: `kubectl get secret insideinfo-web-tls-secret -n default -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -dates`

---

## B. 자체 CA 인증서

내부 CA에서 발급한 인증서를 사용하는 방식.  
cert-manager로 CA를 구성하고 자동 갱신까지 처리하는 방법을 기준으로 설명한다.  
이미 발급된 `.crt` / `.key` 파일이 있는 경우 B-3부터 진행한다.

> **브라우저 경고**: 자체 CA는 공인 기관이 아니므로 브라우저에서 보안 경고가 뜬다.  
> 내부 PC에 CA 인증서를 신뢰 등록하면 경고가 사라진다 (B-5 참고).

### B-1. 자체 CA 인증서 생성 (cert-manager 사용)

```bash
kubectl apply -f - <<EOF
# selfsigned-issuer로 CA 인증서 발급
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
EOF
```

확인:

```bash
kubectl get certificate -n cert-manager
kubectl get clusterissuer insideinfo-ca-issuer
```

`READY: True` 확인.

### B-2. 서비스용 인증서 발급

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insideinfo-web-tls
  namespace: default
spec:
  secretName: insideinfo-web-tls-secret
  duration: 8760h     # 1년
  renewBefore: 720h   # 만료 30일 전 자동 갱신
  issuerRef:
    name: insideinfo-ca-issuer
    kind: ClusterIssuer
  dnsNames:
  - www.insideinfo.co.kr
  - insideinfo.co.kr
  - prod.insideinfo   # 내부 도메인도 포함 (선택)
EOF
```

발급 확인:

```bash
# 발급 상태 확인 (READY: True 까지 대기)
kubectl get certificate -n default -w

# Secret 생성 확인
kubectl get secret insideinfo-web-tls-secret -n default
```

### B-3. 이미 발급된 파일이 있는 경우

cert-manager 없이 직접 Secret 생성 (A-2와 동일):

```bash
kubectl create secret tls insideinfo-web-tls-secret \
  --cert=ca-issued-fullchain.crt \
  --key=ca-issued.key \
  -n default
```

### B-4. Gateway에 HTTPS 리스너 추가

A-3과 동일:

```bash
kubectl apply -f - <<EOF
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
      - name: insideinfo-web-tls-secret
    allowedRoutes:
      namespaces:
        from: All
EOF
```

### B-5. gitops 수정 및 HTTP 리다이렉트

A-4, A-5와 동일하게 진행.

### B-6. 브라우저에 CA 인증서 신뢰 등록

자체 CA 인증서를 PC에 등록해야 브라우저 경고가 사라진다.

```bash
# 서버에서 CA 인증서 추출
kubectl get secret insideinfo-ca-secret -n cert-manager \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > insideinfo-ca.crt
```

PC에서 신뢰 등록:

| OS | 방법 |
|----|------|
| **Windows** | `insideinfo-ca.crt` 더블클릭 → "인증서 설치" → "로컬 컴퓨터" → "신뢰할 수 있는 루트 인증 기관" |
| **Mac** | Keychain Access → 인증서 import → 신뢰 설정 "항상 신뢰" |
| **Linux (Chrome)** | `certutil -d sql:$HOME/.pki/nssdb -A -t "CT,," -n insideinfo-ca -i insideinfo-ca.crt` |

---

## C. Let's Encrypt (공인 인증서 자동 발급)

무료 공인 인증서를 자동 발급/갱신하는 방식.  
cert-manager가 `http01` 챌린지로 Let's Encrypt와 통신한다.

> **전제 조건**:
> - DNS에 `www.insideinfo.co.kr` → 외부 IP 등록 완료
> - 외부에서 **80포트** 접근 가능 (방화벽/공유기에서 `외부 80 → 서버:30080` 포워딩 필요)
> - 외부에서 **443포트** 접근 가능 (공통 단계에서 `외부 443 → 서버:30443` 포워딩 설정)

### C-1. DNS 및 포트 접근 확인

```bash
# DNS 확인
nslookup www.insideinfo.co.kr
# → 외부 IP 응답되어야 함

# 외부에서 80 포트 접근 가능한지 확인 (다른 PC에서)
curl -v http://www.insideinfo.co.kr
# → 응답이 와야 함 (내용 무관)
```

### C-2. Let's Encrypt ClusterIssuer 생성

```bash
kubectl apply -f - <<EOF
# staging (테스트용 — 발급 제한 없음, 브라우저에서 경고 뜸)
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
# production (실제 공인 인증서)
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
EOF
```

> Gateway API 환경이므로 반드시 `gatewayHTTPRoute` solver를 사용한다 (Ingress solver 사용 불가).  
> cert-manager가 챌린지 응답을 위한 임시 HTTPRoute를 자동으로 생성/삭제한다.

확인:

```bash
kubectl get clusterissuer
# letsencrypt-staging, letsencrypt-prod 모두 READY: True 확인
```

### C-3. 인증서 발급 — staging 먼저 테스트

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insideinfo-web-tls-staging
  namespace: default
spec:
  secretName: insideinfo-web-tls-staging-secret
  duration: 2160h
  renewBefore: 360h
  issuerRef:
    name: letsencrypt-staging
    kind: ClusterIssuer
  dnsNames:
  - www.insideinfo.co.kr
  - insideinfo.co.kr
EOF
```

발급 상태 추적:

```bash
# Certificate 상태 확인 (1~3분 소요)
kubectl get certificate -n default -w

# 상세 확인 (실패 시 원인 확인)
kubectl describe certificate insideinfo-web-tls-staging -n default

# ACME 챌린지 확인
kubectl get challenge -A
```

`READY: True` 확인 후 staging Secret 삭제:

```bash
kubectl delete certificate insideinfo-web-tls-staging -n default
kubectl delete secret insideinfo-web-tls-staging-secret -n default
```

### C-4. 인증서 발급 — production

```bash
kubectl apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: insideinfo-web-tls
  namespace: default
spec:
  secretName: insideinfo-web-tls-secret
  duration: 2160h     # 90일 (Let's Encrypt 기본)
  renewBefore: 360h   # 만료 15일 전 자동 갱신
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
  - www.insideinfo.co.kr
  - insideinfo.co.kr
EOF
```

발급 확인:

```bash
kubectl get certificate insideinfo-web-tls -n default
kubectl get secret insideinfo-web-tls-secret -n default
```

### C-5. Gateway에 HTTPS 리스너 추가

A-3과 동일:

```bash
kubectl apply -f - <<EOF
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
      - name: insideinfo-web-tls-secret
    allowedRoutes:
      namespaces:
        from: All
EOF
```

### C-6. gitops 수정 및 HTTP 리다이렉트

A-4, A-5와 동일하게 진행.

---

## 공통 — gitops 수정 (모든 시나리오)

### HTTPRoute 템플릿 수정

**`insideinfo-gitops/apps/insideinfo-web/helm/templates/ingress.yaml`**:

```yaml
{{- if .Values.httproute.enabled }}
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {{ include "insideinfo-web.fullname" . }}
  labels:
    {{- include "insideinfo-web.labels" . | nindent 4 }}
spec:
  parentRefs:
  - name: {{ .Values.httproute.gatewayName }}
    namespace: {{ .Values.httproute.gatewayNamespace }}
    {{- if .Values.httproute.sectionName }}
    sectionName: {{ .Values.httproute.sectionName }}
    {{- end }}
  hostnames:
    {{- range .Values.httproute.hostnames }}
  - {{ . | quote }}
    {{- end }}
  rules:
  - backendRefs:
    - name: {{ include "insideinfo-web.fullname" . }}
      port: {{ .Values.service.port }}
{{- end }}
```

### prod values 수정

**`insideinfo-gitops/apps/insideinfo-web/helm/values/prod/inside-web-values.yaml`**:

```yaml
httproute:
  enabled: true
  gatewayName: eg
  gatewayNamespace: default
  sectionName: https            # HTTPS 리스너 지정
  hostnames:
  - prod.insideinfo
  - www.insideinfo.co.kr       # 실제 도메인
  - insideinfo.co.kr           # apex 도메인 (선택)
```

### gitops push 및 ArgoCD Sync

```bash
cd /path/to/insideinfo-gitops
git add apps/insideinfo-web/
git commit -m "feat: prod HTTPS 적용 (www.insideinfo.co.kr)"
git push origin main
```

ArgoCD에서 `insideinfo-web-prod` 수동 Sync.

---

## 최종 확인

```bash
# Gateway 상태
kubectl get gateway eg -o wide

# HTTPRoute 상태
kubectl get httproute -A

# 인증서 상태
kubectl get certificate -A

# HTTPS 접속 테스트
curl -v https://www.insideinfo.co.kr

# HTTP → HTTPS 리다이렉트 테스트
curl -I http://www.insideinfo.co.kr
# → HTTP/1.1 301 응답 확인
```

---

## 트러블슈팅

### 인증서 발급 실패

```bash
kubectl describe certificate insideinfo-web-tls -n default
kubectl get certificaterequest -n default
kubectl get challenge -A
kubectl describe challenge -A
```

흔한 원인:

| 원인 | 확인 방법 | 조치 |
|------|----------|------|
| 외부에서 80포트 미접근 | `curl http://www.insideinfo.co.kr` (외부에서) | 공유기 포트 포워딩 확인 |
| DNS가 외부 IP 미가리킴 | `nslookup www.insideinfo.co.kr` | DNS A 레코드 등록 |
| ClusterIssuer 오류 | `kubectl describe clusterissuer letsencrypt-prod` | 이메일/URL 확인 |
| Gateway solver 미지원 | Challenge 이벤트 메시지 확인 | cert-manager 버전 1.14+ 필요 |

### Gateway HTTPS 리스너 적용 안 됨

```bash
kubectl describe gateway eg
# Status > Listeners 에서 https 리스너 Attached 확인
```

### HTTPRoute가 HTTPS 리스너에 연결 안 됨

```bash
kubectl get httproute insideinfo-web-prod -n insideinfo -o yaml
# status.parents 에서 parentRef sectionName 확인
```

### 인증서 만료 임박

cert-manager는 `renewBefore` 설정에 따라 자동 갱신한다.  
수동 갱신이 필요한 경우:

```bash
kubectl delete certificaterequest -n default --all
# cert-manager가 자동으로 새 CertificateRequest 생성
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
| TLS Secret 이름 | `insideinfo-web-tls-secret` |
| Gateway 이름 | `eg` (`default` 네임스페이스) |
| HTTPS NodePort | `30443` |
| 서비스 도메인 | `www.insideinfo.co.kr`, `insideinfo.co.kr` |
| ACME 이메일 | `qwep0224@insideinfo.co.kr` |
