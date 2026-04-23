#!/bin/bash
# k3s-master.sh
# 필요하면 k3s-common.sh를 자동 실행한 뒤 마스터 노드 설치를 진행
# 사용법: sudo bash k3s-master.sh

set -e
export PATH=$PATH:/usr/local/bin
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMMON_SCRIPT_PATH="${SCRIPT_DIR}/k3s-common.sh"

validate_k3s_env() {
  [ -f /etc/k3s-env ] || return 1

  # shellcheck disable=SC1091
  source /etc/k3s-env

  if [ "${USE_NAT:-}" = "false" ]; then
    [ -n "${DIRECT_BIND_IP:-}" ] || return 1
  elif [ "${USE_NAT:-}" = "true" ]; then
    [ -n "${PRIVATE_IP:-}" ] || return 1
  else
    return 1
  fi

  return 0
}

ensure_k3s_env() {
  if validate_k3s_env; then
    echo '  [확인] /etc/k3s-env 파일이 있고 필수 값도 정상이다.'
    return 0
  fi

  echo ''
  echo '============================================================'
  echo '  [확인] /etc/k3s-env 파일이 없거나 필수 값이 비어 있다.'
  echo '  k3s-common.sh로 초기 세팅을 먼저 수행한다.'
  echo '============================================================'

  if [ ! -f "$COMMON_SCRIPT_PATH" ]; then
    echo "[오류] k3s-common.sh를 찾지 못했습니다: $COMMON_SCRIPT_PATH"
    exit 1
  fi

  bash "$COMMON_SCRIPT_PATH"

  if ! validate_k3s_env; then
    echo '[오류] k3s-common.sh 실행 후에도 /etc/k3s-env 검증에 실패했습니다.'
    echo '다음 항목을 확인하세요.'
    echo '  1. k3s-common.sh 설정 구간'
    echo '  2. /etc/k3s-env 파일 생성 여부'
    echo '  3. NAT 사용 시 PRIVATE_IP 감지 여부'
    exit 1
  fi

  echo '  [확인] k3s-common.sh 실행 후 /etc/k3s-env 검증 완료'
}

ensure_k3s_env

# shellcheck disable=SC1091
source /etc/k3s-env

if [ "$USE_NAT" = false ]; then
  echo "  [NAT 미사용] Direct Bind IP: $DIRECT_BIND_IP"
else
  echo "  [NAT 사용] Private IP: $PRIVATE_IP"
  if [ -n "$EXTERNAL_IP" ]; then
    echo "  [NAT 사용] External IP: $EXTERNAL_IP"
  else
    echo '  [NAT 사용] External IP: 아직 미확인'
  fi
fi
echo ''

echo '======== [1] K3s Server 설치 ========'

if [ "$USE_NAT" = false ]; then
  curl -sfL https://get.k3s.io | sh -s - server \
    --node-ip "$DIRECT_BIND_IP" \
    --tls-san "$DIRECT_BIND_IP" \
    --disable traefik \
    --disable servicelb \
    --write-kubeconfig-mode 644
else
  # NAT 환경: ServiceLB 활성화 (k3s 내장 LB, 노드 IP를 External IP로 할당)
  # MetalLB 대신 ServiceLB를 사용하므로 --disable servicelb 제거
  set -- server \
    --node-ip "$PRIVATE_IP" \
    --advertise-address "$PRIVATE_IP" \
    --tls-san "$PRIVATE_IP" \
    --disable traefik \
    --write-kubeconfig-mode 644

  if [ -n "$EXTERNAL_IP" ]; then
    set -- "$@" --node-external-ip "$EXTERNAL_IP" --tls-san "$EXTERNAL_IP"
  fi

  curl -sfL https://get.k3s.io | sh -s - "$@"
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

echo ''
echo '============================================================'
echo '  K3s 마스터 노드 설치 완료!'
echo '============================================================'
echo ''
if [ "$USE_NAT" = false ]; then
  echo '  API 접속: https://'$DIRECT_BIND_IP':6443'
else
  echo '  내부 접속: https://'$PRIVATE_IP':6443'
  if [ -n "$EXTERNAL_IP" ]; then
    echo '  외부 접속: https://'$EXTERNAL_IP':6443'
  else
    echo '  외부 접속: External IP 확인 후 추가 반영 필요'
  fi
fi
echo ''
echo '  [다음 단계]'
echo '  sudo bash k3s-apps.sh'
echo ''
echo '============================================================'
