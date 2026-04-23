#!/bin/bash
# k3s-apps.sh
# K3s 마스터 설치 완료 후 실행 — 전체 DevOps 스택 설치
# 마스터 1대 단독 운영 기준
# 사용법: sudo bash k3s-apps.sh

set -e

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 구간 — 여기만 수정하세요 ★               │
# └─────────────────────────────────────────────────────────────┘

# ─── [NAT 미사용] MetalLB IP 풀 ──────────────────────────────
# USE_NAT=false 일 때만 사용. 서버 서브넷의 미사용 IP 대역 입력.
# DHCP 범위, 서버 IP와 겹치지 않아야 함.
METALLB_IP_START="192.168.1.200"   # ← 환경에 맞게 변경
METALLB_IP_END="192.168.1.220"     # ← 환경에 맞게 변경

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 끝 — 아래는 수정하지 마세요 ★            │
# └─────────────────────────────────────────────────────────────┘

# ============================================================
# 버전 고정 (호환성 검증 완료)
# ┌────────────────────────────────────────────────────────────┐
# │ Envoy Gateway   v1.7.1  (2026-03-12 최신)                  │
# │ Headlamp        v0.41.0 (2026-03-26 최신)                  │
# │ Loki chart      6.29.0  ← Grafana 11.x 호환 확인 버전      │
# │   * 6.30+ 부터 schema 정책 변경으로 useTestSchema 불필요    │
# │   * kube-prometheus-stack 내장 Grafana 11.x 와 호환        │
# │ kube-prometheus-stack  최신 (버전 고정 안 함)               │
# │   → Loki와 재설치 시 Grafana 버전이 맞춰짐                  │
# └────────────────────────────────────────────────────────────┘
ENVOY_GATEWAY_VERSION="v1.7.1"
HEADLAMP_VERSION="v0.41.0"
LOKI_CHART_VERSION="6.29.0"
ARGOCD_IMAGE_UPDATER_VERSION="1.1.5"

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH=$PATH:/usr/local/bin

# ============================================================
# 환경 변수 로드 (k3s-common.sh에서 생성한 /etc/k3s-env 사용)
# ============================================================
if [ -f /etc/k3s-env ]; then
  source /etc/k3s-env
else
  echo '[오류] /etc/k3s-env 파일이 없습니다. k3s-common.sh를 먼저 실행하세요.'
  exit 1
fi

if [ "$USE_NAT" = true ]; then
  echo "  [NAT 사용] Private IP: $PRIVATE_IP"
  if [ -n "$EXTERNAL_IP" ]; then
    echo "  [NAT 사용] External IP: $EXTERNAL_IP"
    echo "  [NAT 사용] 외부 접속: http://<도메인>:30080"
  else
    echo '  [NAT 사용] External IP: 아직 미확인'
    echo "  [NAT 사용] 내부 접속: http://${PRIVATE_IP}:30080"
  fi
  echo ''
fi


echo '======== 노드 상태 확인 ========'
kubectl get nodes -o wide
echo ''


echo '======== [1] Helm 설치 ========'
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version


# ============================================================
# [2] LoadBalancer 구성 (환경별 분기)
# ============================================================
if [ "$USE_NAT" = false ]; then
  echo '======== [2] MetalLB 설치 (NAT 미사용 환경) ========'
  helm repo add metallb https://metallb.github.io/metallb
  helm repo update
  helm upgrade --install metallb metallb/metallb \
    --create-namespace --namespace metallb-system \
    --wait --timeout 600s

  echo '======== [2-1] MetalLB IP Pool 설정 ========'
  kubectl wait --namespace metallb-system \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/name=metallb \
    --timeout=600s

  cat <<EOF | kubectl apply -f -
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_START}-${METALLB_IP_END}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: default-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF

else
  echo '======== [2] [NAT 사용] MetalLB 건너뜀 → ServiceLB 방식 사용 ========'
  echo '  k3s 내장 ServiceLB가 Envoy Gateway에 노드 IP를 External IP로 할당합니다.'
  echo '  공유기에서 외부 80/443 → 서버 80/443 포트포워딩이 필요합니다.'
fi


echo "======== [3] Envoy Gateway (Gateway API) 설치 — ${ENVOY_GATEWAY_VERSION} ========"
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version ${ENVOY_GATEWAY_VERSION} \
  -n envoy-gateway-system \
  --create-namespace

echo '======== [3-1] Envoy Gateway 준비 대기 ========'
kubectl wait --timeout=600s -n envoy-gateway-system \
  deployment/envoy-gateway --for=condition=Available

echo '======== [3-2] GatewayClass + Gateway 생성 ========'
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
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
EOF

if [ "$USE_NAT" = true ]; then
  echo '======== [3-3] [NAT 사용] Envoy Gateway ServiceLB External IP 대기 ========'
  # ServiceLB(Klipper)가 LoadBalancer 서비스에 노드 IP를 자동 할당
  # NodePort 패치 불필요 — 표준 포트 80/443으로 직접 바인딩됨
  sleep 15  # envoy 서비스 생성 대기
  ENVOY_SVC=$(kubectl get svc -n envoy-gateway-system \
    -l gateway.envoyproxy.io/owning-gateway-name=eg \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

  if [ -n "$ENVOY_SVC" ]; then
    for i in $(seq 1 20); do
      EXT_IP=$(kubectl get svc "$ENVOY_SVC" -n envoy-gateway-system \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
      if [ -n "$EXT_IP" ]; then
        echo "  ✓ Envoy Service ($ENVOY_SVC) → External IP: $EXT_IP (포트 80/443)"
        break
      fi
      sleep 3
    done
    if [ -z "$EXT_IP" ]; then
      echo "  ✓ Envoy Service ($ENVOY_SVC) → LoadBalancer 준비 중 (IP 할당 대기)"
      echo '  kubectl get svc -n envoy-gateway-system 으로 확인하세요.'
    fi
  else
    echo '  [경고] Envoy 서비스를 찾지 못했습니다.'
    echo '  kubectl get svc -n envoy-gateway-system 으로 확인하세요.'
  fi
fi


echo '======== [4] cert-manager 설치 ========'
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --create-namespace --namespace cert-manager \
  --set crds.enabled=true

echo '======== [4-1] Self-Signed ClusterIssuer 생성 ========'
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF


echo "======== [5] Headlamp (클러스터 웹 UI) 설치 — ${HEADLAMP_VERSION} ========"
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
helm upgrade --install headlamp headlamp/headlamp \
  --create-namespace --namespace headlamp \
  --set image.tag="${HEADLAMP_VERSION}"

# ┌─────────────────────────────────────────────────────────────┐
# │ v0.41.0 부터 -session-ttl 플래그가 정식 지원되므로           │
# │ 기존 args 패치(강제 교체)가 불필요해졌습니다.                │
# │ 단, -in-cluster-context-name 커스터마이징은 유지합니다.      │
# └─────────────────────────────────────────────────────────────┘
echo '======== [5-1] Headlamp in-cluster-context-name 패치 ========'
kubectl rollout status deployment headlamp -n headlamp --timeout=180s
kubectl -n headlamp patch deployment headlamp --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": [
    "-in-cluster",
    "-in-cluster-context-name=main",
    "-plugins-dir=/headlamp/plugins"
  ]}
]'
kubectl rollout status deployment headlamp -n headlamp --timeout=120s


echo '======== [6] kube-prometheus-stack (Prometheus + Grafana) 설치 ========'
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
# ┌─────────────────────────────────────────────────────────────┐
# │ 버전 미지정 → 최신(현재 82.x) 설치                          │
# │ 내장 Grafana: 11.x                                          │
# │ Loki chart 6.29.0 과 Grafana 11.x 호환 확인됨               │
# └─────────────────────────────────────────────────────────────┘
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --create-namespace --namespace monitoring \
  --set grafana.adminPassword=admin1234 \
  --set prometheus.prometheusSpec.retention=7d \
  --wait --timeout 600s


echo "======== [7] Loki (로그 저장소) 설치 — chart ${LOKI_CHART_VERSION} / SingleBinary + filesystem ========"
# ┌─────────────────────────────────────────────────────────────┐
# │ 버전 고정 이유: Grafana 11.x 와 호환 확인된 버전            │
# │   - 6.30+ 부터 internal schema 정책 변경                    │
# │   - 6.29.x 는 useTestSchema / rulerConfig 옵션 정상 동작    │
# │ Loki app version: 3.3.x                                     │
# └─────────────────────────────────────────────────────────────┘
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install loki grafana/loki \
  --version ${LOKI_CHART_VERSION} \
  --create-namespace --namespace logging \
  --set deploymentMode=SingleBinary \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.useTestSchema=true \
  --set loki.auth_enabled=false \
  --set loki.rulerConfig.storage.type=local \
  --set singleBinary.replicas=1 \
  --set singleBinary.persistence.enabled=false \
  --set minio.enabled=false \
  --set backend.replicas=0 \
  --set read.replicas=0 \
  --set write.replicas=0 \
  --set ingester.replicas=0 \
  --set querier.replicas=0 \
  --set queryFrontend.replicas=0 \
  --set queryScheduler.replicas=0 \
  --set distributor.replicas=0 \
  --set compactor.replicas=0 \
  --set indexGateway.replicas=0 \
  --set bloomCompactor.replicas=0 \
  --set bloomGateway.replicas=0 \
  --set chunksCache.enabled=false \
  --set resultsCache.enabled=false \
  --set singleBinary.extraVolumes[0].name=data \
  --set singleBinary.extraVolumes[0].emptyDir.sizeLimit=5Gi \
  --set singleBinary.extraVolumeMounts[0].name=data \
  --set singleBinary.extraVolumeMounts[0].mountPath=/var/loki

echo '======== [7-1] Grafana Alloy (로그 수집 에이전트) 설치 ========'
helm upgrade --install alloy grafana/alloy \
  --namespace logging \
  --set alloy.configMap.content='
logging {
  level  = "info"
  format = "logfmt"
}

discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets
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
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.endpoint.receiver]
}

loki.write "endpoint" {
  endpoint {
    url = "http://loki-gateway.logging.svc.cluster.local/loki/api/v1/push"
  }
}
'

echo '======== [7-2] Loki 데이터소스 Grafana에 자동 프로비저닝 ========'
# ┌─────────────────────────────────────────────────────────────┐
# │ Grafana UI에서 수동 추가 대신 ConfigMap으로 자동 등록        │
# │ kube-prometheus-stack의 grafana sidecar가 감지해서 로드      │
# └─────────────────────────────────────────────────────────────┘
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: loki-datasource
  namespace: monitoring
  labels:
    grafana_datasource: "1"
data:
  loki-datasource.yaml: |-
    apiVersion: 1
    datasources:
    - name: Loki
      type: loki
      access: proxy
      url: http://loki-gateway.logging.svc.cluster.local
      isDefault: false
      version: 1
      editable: true
EOF


# [8] Sealed Secrets — SOPS로 대체하여 더 이상 사용하지 않음 (06-SOPS 가이드 참고)
# helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
# helm repo update
# helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
#   --create-namespace --namespace kube-system \
#   --set-string fullnameOverride=sealed-secrets-controller
# KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
# curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
# tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
# install -m 755 kubeseal /usr/local/bin/kubeseal
# rm -f kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal


echo '======== [8] Argo CD 설치 (Helm + SOPS 시크릿 복호화) ========'
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update

cat > /tmp/argocd-values.yaml << 'ARGOEOF'
configs:
  params:
    server.insecure: true

repoServer:
  env:
    - name: SOPS_AGE_KEY_FILE
      value: /app/config/age/keys.txt
    - name: HELM_PLUGINS
      value: /custom-tools/helm-plugins

  volumes:
    - name: sops-age
      secret:
        secretName: sops-age
    - name: custom-tools
      emptyDir: {}

  volumeMounts:
    - name: sops-age
      mountPath: /app/config/age
    - name: custom-tools
      mountPath: /usr/local/bin/sops
      subPath: sops
    - name: custom-tools
      mountPath: /custom-tools/helm-plugins
      subPath: helm-plugins

  initContainers:
    - name: install-sops
      image: alpine:3.20
      command:
        - sh
        - -c
        - |
          wget -qO /custom-tools/sops \
            https://github.com/getsops/sops/releases/download/v3.9.4/sops-v3.9.4.linux.amd64 \
          && chmod +x /custom-tools/sops
      volumeMounts:
        - name: custom-tools
          mountPath: /custom-tools
    - name: install-helm-secrets
      image: alpine/helm:3.16.4
      command:
        - sh
        - -c
        - |
          helm plugin install https://github.com/jkroepke/helm-secrets --version v4.6.2 \
          && PDIR=/root/.local/share/helm/plugins/helm-secrets \
          && printf 'name: "secrets"\nversion: "4.6.2"\nusage: "Secrets encryption in Helm for Git storing"\ndescription: "This plugin provides secrets values encryption for Helm charts secure storing"\nuseTunnel: false\ncommand: "$HELM_PLUGIN_DIR/scripts/run.sh"\ndownloaders:\n  - command: "scripts/run.sh downloader"\n    protocols:\n      - "secrets"\n      - "secrets+gpg-import"\n      - "secrets+gpg-import-kubernetes"\n      - "secrets+age-import"\n      - "secrets+age-import-kubernetes"\n      - "secrets+literal"\n' > $PDIR/plugin.yaml \
          && cp -r /root/.local/share/helm/plugins/* /custom-tools/helm-plugins/
      volumeMounts:
        - name: custom-tools
          mountPath: /custom-tools/helm-plugins
          subPath: helm-plugins
ARGOEOF

helm upgrade --install argocd argo/argo-cd \
  --create-namespace --namespace argocd \
  -f /tmp/argocd-values.yaml \
  --wait --timeout 600s

echo '======== [8-1] Argo CD 기본 로그인 비밀번호 admin 으로 고정 ========'
kubectl rollout status deployment argocd-server -n argocd --timeout=300s
ARGOCD_ADMIN_HASH=$(kubectl -n argocd exec deploy/argocd-server -- \
  argocd account bcrypt --password 'admin')
kubectl -n argocd patch secret argocd-secret --type merge \
  -p "{\"stringData\":{\"admin.password\":\"$ARGOCD_ADMIN_HASH\",\"admin.passwordMtime\":\"$(date -u +%FT%TZ)\"}}"
kubectl -n argocd delete secret argocd-initial-admin-secret --ignore-not-found=true
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=300s

echo '======== [8-2] Argo CD helm.valuesFileSchemes 설정 (secrets:// 스킴 허용) ========'
# ┌─────────────────────────────────────────────────────────────┐
# │ helm-secrets의 secrets:// 프로토콜을 ArgoCD가 허용하도록 설정  │
# │ 미설정 시 "URL scheme 'secrets' is not allowed" 에러 발생     │
# └─────────────────────────────────────────────────────────────┘
kubectl patch configmap argocd-cm -n argocd --type merge \
  -p '{"data":{"helm.valuesFileSchemes": "secrets,secrets+gpg-import,secrets+gpg-import-kubernetes,secrets+age-import,secrets+age-import-kubernetes,secrets+literal,https,http"}}'
kubectl rollout restart deployment argocd-repo-server -n argocd
kubectl rollout status deployment argocd-repo-server -n argocd --timeout=120s


echo "======== [9] Argo CD Image Updater 설치 (Helm, v${ARGOCD_IMAGE_UPDATER_VERSION}) ========"
helm upgrade --install argocd-image-updater argo/argocd-image-updater \
  --namespace argocd \
  --version ${ARGOCD_IMAGE_UPDATER_VERSION} \
  --wait --timeout 300s


echo '======== [10] HTTPRoute 도메인 라우팅 설정 ========'

echo '======== [10-1] ReferenceGrant (cross-namespace 접근 허용) ========'
for NS in monitoring argocd headlamp; do
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1beta1
kind: ReferenceGrant
metadata:
  name: allow-gateway-ref
  namespace: $NS
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    namespace: default
  to:
  - group: ""
    kind: Service
EOF
done

echo '======== [10-2] Grafana (grafana.local → HTTP:80) ========'
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: grafana
  namespace: default
spec:
  parentRefs:
  - name: eg
  hostnames:
  - "grafana.local"
  rules:
  - backendRefs:
    - name: kube-prometheus-stack-grafana
      namespace: monitoring
      port: 80
EOF

echo '======== [10-3] Prometheus (prometheus.local → HTTP:9090) ========'
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: prometheus
  namespace: default
spec:
  parentRefs:
  - name: eg
  hostnames:
  - "prometheus.local"
  rules:
  - backendRefs:
    - name: kube-prometheus-stack-prometheus
      namespace: monitoring
      port: 9090
EOF

echo '======== [10-4] ArgoCD (argocd.local → HTTP:80) ========'
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: default
spec:
  parentRefs:
  - name: eg
  hostnames:
  - "argocd.local"
  rules:
  - backendRefs:
    - name: argocd-server
      namespace: argocd
      port: 80
EOF

echo '======== [10-5] Headlamp (dashboard.local → HTTP:80) ========'
cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: headlamp
  namespace: default
spec:
  parentRefs:
  - name: eg
  hostnames:
  - "dashboard.local"
  rules:
  - backendRefs:
    - name: headlamp
      namespace: headlamp
      port: 80
EOF


# ============================================================
# Gateway/접속 IP 확정
# ============================================================
if [ "$USE_NAT" = false ]; then
  echo '======== [10-6] Gateway External IP 확인 (MetalLB) ========'
  echo '  MetalLB IP 할당 대기 중...'
  for i in $(seq 1 30); do
    GATEWAY_IP=$(kubectl get gateway eg -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
    if [ -n "$GATEWAY_IP" ]; then
      echo "  ✓ Gateway External IP: $GATEWAY_IP"
      break
    fi
    sleep 5
  done
  if [ -z "$GATEWAY_IP" ]; then
    echo '  [경고] Gateway에 IP가 아직 할당되지 않았습니다.'
    echo '  kubectl get gateway eg 으로 확인하세요.'
    GATEWAY_IP="<GATEWAY_IP>"
  fi

else
  # ServiceLB가 노드 IP를 External IP로 할당 → Gateway status에서 읽기
  echo '======== [10-6] Gateway External IP 확인 (ServiceLB) ========'
  for i in $(seq 1 20); do
    GATEWAY_IP=$(kubectl get gateway eg -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
    if [ -n "$GATEWAY_IP" ]; then
      echo "  ✓ Gateway IP (ServiceLB): $GATEWAY_IP"
      break
    fi
    sleep 3
  done
  if [ -z "$GATEWAY_IP" ]; then
    GATEWAY_IP="${EXTERNAL_IP:-$PRIVATE_IP}"
    echo "  [참고] Gateway IP 자동 확인 실패 → 서버 IP 사용: $GATEWAY_IP"
  fi
fi


# ============================================================
# 완료 메시지
# ============================================================
echo ''
echo '============================================================'
echo '  전체 스택 + HTTPRoute 설정 완료!'
echo '============================================================'
echo ''
echo '  [1] 접속할 PC의 hosts 파일에 도메인 추가 (필수)'
echo ''
echo '      # Linux/Mac: /etc/hosts'
echo '      # Windows: C:\Windows\System32\drivers\etc\hosts'
echo ''
echo "      $GATEWAY_IP  grafana.local"
echo "      $GATEWAY_IP  prometheus.local"
echo "      $GATEWAY_IP  argocd.local"
echo "      $GATEWAY_IP  dashboard.local"
echo ''

if [ "$USE_NAT" = false ]; then
  echo '  [2] 브라우저 접속'
  echo '      Grafana      http://grafana.local       (admin / admin1234)'
  echo '      Prometheus   http://prometheus.local     (인증 없음)'
  echo '      ArgoCD       http://argocd.local         (admin / admin)'
  echo '      Headlamp     http://dashboard.local      (토큰 로그인)'
else
  if [ -n "$EXTERNAL_IP" ]; then
    echo '  [2] 브라우저 접속 [NAT 사용: 공유기 포트포워딩 필요 (외부 80/443 → 서버 80/443)]'
  else
    echo '  [2] 브라우저 접속 [NAT 사용: ServiceLB, 공유기 포트포워딩 설정 필요]'
    echo '      External IP를 아직 모르므로 외부 인터넷 접속 안내는 생략합니다.'
  fi
  echo '      Grafana      http://grafana.local       (admin / admin1234)'
  echo '      Prometheus   http://prometheus.local     (인증 없음)'
  echo '      ArgoCD       http://argocd.local         (admin / admin)'
  echo '      Headlamp     http://dashboard.local      (토큰 로그인)'
  echo ''
  echo '  [포트포워딩] 공유기에서 아래 설정 필요:'
  echo "      외부 80  → $GATEWAY_IP:80"
  echo "      외부 443 → $GATEWAY_IP:443"
fi
echo ''
echo '  [3] ArgoCD 기본 로그인'
echo '      admin / admin'
echo ''
echo '  [4] Headlamp 로그인 토큰'
echo '      kubectl -n headlamp create token headlamp'
echo ''
echo '  [5] Grafana Loki 데이터소스'
echo '      ConfigMap 자동 프로비저닝으로 등록됨 (수동 추가 불필요)'
echo '      확인: Grafana → Connections → Data Sources → Loki'
echo '      URL: http://loki-gateway.logging.svc.cluster.local'
echo ''
echo '  [6] HTTPRoute 상태 확인'
echo '      kubectl get httproute'
echo '      kubectl get gateway eg'
echo ''
echo '============================================================'
