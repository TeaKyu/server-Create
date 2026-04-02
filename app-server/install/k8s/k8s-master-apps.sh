#!/bin/bash
# k8s-master-apps.sh
# 워커 노드 조인 완료 후, Master 노드에서 실행
# 사용법: sudo bash k8s-master-apps.sh

set -e
export PATH=$PATH:/usr/local/bin

echo '======== 워커 노드 상태 확인 ========'
kubectl get nodes
echo ''
read -p "워커 노드가 모두 Ready 상태인가요? (y/n): " confirm
if [ "$confirm" != "y" ]; then
  echo "워커 노드를 먼저 조인하세요."
  exit 1
fi


echo '======== [6] Helm 설치 ========'
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version


echo '======== [7] MetalLB 설치 (온프레미스 LoadBalancer) ========'
helm repo add metallb https://metallb.github.io/metallb
helm repo update
helm upgrade --install metallb metallb/metallb \
  --create-namespace --namespace metallb-system \
  --wait --timeout 600s

echo '======== [7-1] MetalLB IP Pool 설정 (192.168.56.200~220) ========'
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
  - 192.168.56.200-192.168.56.220
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


echo '======== [8] Envoy Gateway (Gateway API) 설치 ========'
helm install eg oci://docker.io/envoyproxy/gateway-helm \
  --version v1.7.1 \
  -n envoy-gateway-system \
  --create-namespace

echo '======== [8-1] Envoy Gateway 준비 대기 ========'
kubectl wait --timeout=600s -n envoy-gateway-system \
  deployment/envoy-gateway --for=condition=Available

echo '======== [8-2] GatewayClass + Gateway 생성 ========'
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


echo '======== [9] cert-manager 설치 ========'
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm upgrade --install cert-manager jetstack/cert-manager \
  --create-namespace --namespace cert-manager \
  --set crds.enabled=true

echo '======== [9-1] Self-Signed ClusterIssuer 생성 (온프레미스용) ========'
cat <<EOF | kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned-issuer
spec:
  selfSigned: {}
EOF


echo '======== [10] Headlamp (클러스터 웹 UI) 설치 ========'
# Kubernetes Dashboard는 2026년 1월 아카이브됨 → 공식 후속 도구 Headlamp 사용
# 차트 0.40.x에서 -session-ttl 플래그 호환 문제 있어 설치 후 패치 필요
helm repo add headlamp https://kubernetes-sigs.github.io/headlamp/
helm repo update
helm upgrade --install headlamp headlamp/headlamp \
  --create-namespace --namespace headlamp \
  --set image.tag="v0.40.1"

echo '======== [10-1] Headlamp -session-ttl 호환 패치 ========'
# 차트가 -session-ttl 플래그를 주입하지만 이미지가 미지원 → 해당 arg 제거
kubectl -n headlamp patch deployment headlamp --type='json' -p='[
  {"op": "replace", "path": "/spec/template/spec/containers/0/args", "value": [
    "-in-cluster",
    "-in-cluster-context-name=main",
    "-plugins-dir=/headlamp/plugins"
  ]}
]'
kubectl rollout status deployment headlamp -n headlamp --timeout=120s

echo '======== [10-2] Headlamp 권한 확인 ========'
# Helm 차트가 headlamp SA + cluster-admin ClusterRoleBinding을 자동 생성합니다.
# 별도 ServiceAccount 생성이 필요 없습니다.
# 토큰 생성: kubectl -n headlamp create token headlamp


echo '======== [11] kube-prometheus-stack (Prometheus + Grafana) 설치 ========'
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --create-namespace --namespace monitoring \
  --set grafana.adminPassword=admin1234 \
  --set prometheus.prometheusSpec.retention=7d


echo '======== [12] Loki (로그 저장소) 설치 — SingleBinary + filesystem ========'
# loki-stack(deprecated) 대신 공식 loki 차트 사용
# SingleBinary 모드 + filesystem 스토리지 + emptyDir (학습 환경)
# 운영 환경에서는 S3/GCS 등 오브젝트 스토리지로 교체
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install loki grafana/loki \
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

echo '======== [12-1] Grafana Alloy (로그 수집 에이전트) 설치 ========'
# Promtail(EOL 2026-03-02) 대신 공식 후속 도구 Alloy 사용
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


echo '======== [13] Sealed Secrets (GitOps Secret 암호화) 설치 ========'
helm repo add sealed-secrets https://bitnami-labs.github.io/sealed-secrets
helm repo update
helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --create-namespace --namespace kube-system \
  --set-string fullnameOverride=sealed-secrets-controller

echo '======== [13-1] kubeseal CLI 설치 ========'
KUBESEAL_VERSION=$(curl -s https://api.github.com/repos/bitnami-labs/sealed-secrets/releases/latest | grep '"tag_name"' | sed -E 's/.*"v([^"]+)".*/\1/')
curl -OL "https://github.com/bitnami-labs/sealed-secrets/releases/download/v${KUBESEAL_VERSION}/kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz"
tar -xvzf kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal
install -m 755 kubeseal /usr/local/bin/kubeseal
rm -f kubeseal-${KUBESEAL_VERSION}-linux-amd64.tar.gz kubeseal


echo '======== [14] Argo CD v3.3.3 설치 ========'
kubectl create namespace argocd
kubectl apply -n argocd --server-side --force-conflicts \
  -f https://raw.githubusercontent.com/argoproj/argo-cd/v3.3.3/manifests/install.yaml

echo '======== [14-1] ArgoCD insecure 모드 (TLS 비활성화 → HTTP:80) ========'
# Gateway가 앞단에서 TLS를 처리하므로 ArgoCD 자체 TLS는 끔
# insecure 모드: port 8080(HTTP), Service port 80 → 8080
kubectl patch configmap argocd-cmd-params-cm -n argocd --type merge \
  -p '{"data":{"server.insecure":"true"}}'
kubectl rollout restart deployment argocd-server -n argocd
kubectl rollout status deployment argocd-server -n argocd --timeout=300s


echo '======== [15] Argo CD Image Updater 설치 ========'
kubectl apply -n argocd \
  -f https://raw.githubusercontent.com/argoproj-labs/argocd-image-updater/stable/config/install.yaml


echo '======== [16] HTTPRoute 도메인 라우팅 설정 ========'

echo '======== [16-1] ReferenceGrant (cross-namespace 접근 허용) ========'
# default 네임스페이스의 HTTPRoute가 다른 네임스페이스의 Service를 참조하려면 필요
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

echo '======== [16-2] Grafana (grafana.local → HTTP:80) ========'
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

echo '======== [16-3] Prometheus (prometheus.local → HTTP:9090) ========'
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

echo '======== [16-4] ArgoCD (argocd.local → HTTP:80, insecure 모드) ========'
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

echo '======== [16-5] Headlamp (dashboard.local → HTTP:80) ========'
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

echo '======== [16-6] Gateway External IP 확인 ========'
echo '  MetalLB IP 할당 대기 중...'
for i in $(seq 1 30); do
  GW_IP=$(kubectl get gateway eg -o jsonpath='{.status.addresses[0].value}' 2>/dev/null)
  if [ -n "$GW_IP" ]; then
    echo "  Gateway External IP: $GW_IP"
    break
  fi
  sleep 5
done

if [ -z "$GW_IP" ]; then
  echo '  [경고] Gateway에 IP가 아직 할당되지 않았습니다.'
  echo '  kubectl get gateway eg 으로 확인하세요.'
  GW_IP="<GATEWAY_IP>"
fi


echo ''
echo '============================================================'
echo '  전체 스택 + HTTPRoute 설정 완료!'
echo '============================================================'
echo ''
echo '  [1] Windows hosts 파일 설정 (필수)'
echo '      메모장을 관리자 권한으로 열고 아래 파일에 추가:'
echo '      C:\Windows\System32\drivers\etc\hosts'
echo ''
echo "      $GW_IP  grafana.local"
echo "      $GW_IP  prometheus.local"
echo "      $GW_IP  argocd.local"
echo "      $GW_IP  dashboard.local"
echo ''
echo '  [2] 브라우저 접속'
echo '      Grafana      http://grafana.local       (admin / admin1234)'
echo '      Prometheus   http://prometheus.local     (인증 없음)'
echo '      ArgoCD       http://argocd.local         (admin / 아래 명령어로 확인)'
echo '      Headlamp     http://dashboard.local      (토큰 로그인)'
echo ''
echo '  [3] ArgoCD 초기 비밀번호'
echo '      kubectl -n argocd get secret argocd-initial-admin-secret \'
echo '        -o jsonpath="{.data.password}" | base64 -d; echo'
echo ''
echo '  [4] Headlamp 로그인 토큰'
echo '      kubectl -n headlamp create token headlamp'
echo ''
echo '  [5] Grafana에서 Loki 데이터소스 추가'
echo '      Connections → Data Sources → Add → Loki'
echo '      URL: http://loki-gateway.logging.svc.cluster.local'
echo ''
echo '  [6] HTTPRoute 상태 확인'
echo '      kubectl get httproute'
echo '      kubectl get gateway eg'
echo ''
echo '============================================================'
