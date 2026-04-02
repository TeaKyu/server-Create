#!/bin/bash
# k3s-master.sh
# k3s-common.sh 실행 완료 후, 마스터 노드에서 실행
# K3s는 containerd + kubectl + CNI(Flannel)를 모두 내장
# 사용법: sudo bash k3s-master.sh

set -e

# ============================================================
# 환경 변수 (서버 환경에 맞게 수정)
# ============================================================
MASTER_IP="192.168.1.10"


echo '======== [1] K3s Server 설치 ========'
# --disable traefik     : 기본 Traefik 비활성화 (Envoy Gateway 사용)
# --disable servicelb   : 기본 ServiceLB 비활성화 (MetalLB 사용)
# --write-kubeconfig-mode 644 : kubeconfig 파일 권한
# --tls-san             : API 서버 인증서에 포함할 IP
# --node-ip             : 멀티 NIC 환경에서 올바른 IP 지정

curl -sfL https://get.k3s.io | sh -s - server \
  --disable traefik \
  --disable servicelb \
  --write-kubeconfig-mode 644 \
  --tls-san "$MASTER_IP" \
  --node-ip "$MASTER_IP"

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

echo ''
echo '============================================================'
echo '  K3s 마스터 노드 설치 완료!'
echo '============================================================'
echo ''
echo '  [다음 단계]'
echo '  sudo bash k3s-apps.sh'
echo ''
echo '============================================================'
