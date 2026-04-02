#!/bin/bash
# k3s-master.sh
# k3s-common.sh 실행 완료 후, 마스터 노드에서 실행
# K3s는 containerd + kubectl + CNI(Flannel)를 모두 내장
# 사용법: sudo bash k3s-master.sh

set -e
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

# 로드된 변수 확인
if [ "$IS_OCI" = false ]; then
  echo "  [일반 서버] Master IP: $MASTER_IP"
else
  echo "  [OCI] Private IP (NIC 바인딩): $PRIVATE_IP"
  echo "  [OCI] Public IP  (NAT 매핑):   $PUBLIC_IP"
fi
echo ''


echo '======== [1] K3s Server 설치 ========'

if [ "$IS_OCI" = false ]; then
  # ─────────────────────────────────────────────────────────────
  # [일반 서버] 고정 IP 기반 설치
  #   --node-ip    : 노드 IP (클러스터 내부 통신)
  #   --tls-san    : API 서버 인증서 SAN (외부 kubectl 접속 시 필요)
  #   --disable traefik   : Traefik 비활성화 (Envoy Gateway 사용)
  #   --disable servicelb : ServiceLB 비활성화 (MetalLB 사용)
  # ─────────────────────────────────────────────────────────────
  curl -sfL https://get.k3s.io | sh -s - server \
    --node-ip "$MASTER_IP" \
    --tls-san "$MASTER_IP" \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 644

else
  # ┌─────────────────────────────────────────────────────────┐
  # │ [OCI 전용] OCI 네트워크 구조 대응 설치                   │
  # │                                                         │
  # │  OCI 인스턴스: NIC → Private IP (실제 바인딩)            │
  # │                IGW → Public IP  (NAT 매핑, NIC 없음)    │
  # │                                                         │
  # │  --node-ip           : 클러스터 내부 통신 (Private)      │
  # │  --advertise-address : API Server 광고 주소 (Private)   │
  # │  --node-external-ip  : 외부 인식 IP (Public, OCI NAT)   │
  # │  --tls-san           : kubeconfig 인증서 SAN             │
  # │                        Public + Private 모두 추가        │
  # │  --disable servicelb : MetalLB 없이 NodePort 직접 사용  │
  # └─────────────────────────────────────────────────────────┘
  curl -sfL https://get.k3s.io | sh -s - server \
    --node-ip            "$PRIVATE_IP" \
    --advertise-address  "$PRIVATE_IP" \
    --node-external-ip   "$PUBLIC_IP"  \
    --tls-san            "$PUBLIC_IP"  \
    --tls-san            "$PRIVATE_IP" \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 644
fi

systemctl status k3s --no-pager


echo '======== [2] kubectl 설정 ========'
mkdir -p $HOME/.kube
cp /etc/rancher/k3s/k3s.yaml $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

grep -q 'KUBECONFIG' ~/.bashrc || cat >> ~/.bashrc << 'EOF'
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
EOF
export KUBECONFIG=/etc/rancher/k3s/k3s.yaml


echo '======== [3] kubectl 편의기능 ========'
grep -q 'kubectl completion' ~/.bashrc || cat >> ~/.bashrc << 'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF


echo '======== [4] 노드 상태 확인 ========'
kubectl get nodes -o wide


echo '======== [5] kubectl 편의기능 ========'
echo "source <(kubectl completion bash)" >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc



echo ''
echo '============================================================'
echo '  K3s 마스터 노드 설치 완료!'
echo '============================================================'
echo ''
if [ "$IS_OCI" = false ]; then
  echo '  [일반 서버] kubectl 접속: https://'$MASTER_IP':6443'
else
  echo '  [OCI] kubectl 접속 (외부): https://'$PUBLIC_IP':6443'
  echo '  [OCI] kubectl 접속 (내부): https://'$PRIVATE_IP':6443'
fi
echo ''
echo '  [다음 단계]'
echo '  sudo bash k3s-apps.sh'
echo ''
echo '============================================================'
