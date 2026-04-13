#!/bin/bash
# k8s-master.sh
# k8s-common.sh 실행 완료 후, Master 노드에서만 실행
# 이후 순서: 워커 조인 → k8s-master-apps.sh
# 사용법: sudo bash k8s-master.sh

set -e
export PATH=$PATH:/usr/local/bin
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMMON_SCRIPT_PATH="${SCRIPT_DIR}/k8s-common.sh"

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 구간 — 여기만 수정하세요 ★               │
# └─────────────────────────────────────────────────────────────┘

# Pod Network CIDR (기본값 변경 불필요)
POD_NETWORK_CIDR="10.96.0.0/12"

# CNI 플러그인 버전
CALICO_VERSION="v3.31.4"

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 끝 — 아래는 수정하지 마세요 ★            │
# └─────────────────────────────────────────────────────────────┘

validate_k8s_env() {
  [ -f /etc/k8s-env ] || return 1

  # shellcheck disable=SC1091
  source /etc/k8s-env

  case "${IS_VAGRANT:-}" in
    true)
      [ -n "${MASTER_IP:-}" ] || return 1
      [ -n "${MASTER_HOSTNAME:-}" ] || return 1
      [ -n "${WORKER1_HOSTNAME:-}" ] || return 1
      [ -n "${WORKER1_IP:-}" ] || return 1
      [ -n "${WORKER2_HOSTNAME:-}" ] || return 1
      [ -n "${WORKER2_IP:-}" ] || return 1
      ;;
    false)
      [ -n "${MASTER_IP:-}" ] || return 1
      [ -n "${MASTER_HOSTNAME:-}" ] || return 1
      ;;
    *)
      return 1
      ;;
  esac

  return 0
}

ensure_k8s_env() {
  if validate_k8s_env; then
    echo '  [확인] /etc/k8s-env 파일이 있고 필수 값도 정상이다.'
    return 0
  fi

  echo ''
  echo '============================================================'
  echo '  [확인] /etc/k8s-env 파일이 없거나 필수 값이 비어 있다.'
  echo '  k8s-common.sh로 초기 세팅을 먼저 수행한다.'
  echo '============================================================'

  if [ ! -f "$COMMON_SCRIPT_PATH" ]; then
    echo "[오류] k8s-common.sh를 찾지 못했습니다: $COMMON_SCRIPT_PATH"
    exit 1
  fi

  bash "$COMMON_SCRIPT_PATH"

  if ! validate_k8s_env; then
    echo '[오류] k8s-common.sh 실행 후에도 /etc/k8s-env 검증에 실패했습니다.'
    echo '다음 항목을 확인하세요.'
    echo '  1. k8s-common.sh 설정 구간'
    echo '  2. /etc/k8s-env 파일 생성 여부'
    echo '  3. IS_VAGRANT 및 MASTER_IP 값'
    exit 1
  fi

  echo '  [확인] k8s-common.sh 실행 후 /etc/k8s-env 검증 완료'
}

ensure_k8s_env

# ============================================================
# 환경 변수 로드 (k8s-common.sh에서 생성한 /etc/k8s-env 사용)
# ============================================================
if [ -f /etc/k8s-env ]; then
  # shellcheck disable=SC1091
  source /etc/k8s-env
else
  echo '[오류] /etc/k8s-env 파일이 없습니다. k8s-common.sh를 먼저 실행하세요.'
  exit 1
fi

# 로드된 변수 확인
if [ "$IS_VAGRANT" = true ]; then
  echo "  [Vagrant] Master IP: $MASTER_IP"
else
  echo "  [일반 서버] Master IP: $MASTER_IP"
fi
echo ''


echo '======== [1] kubeadm 클러스터 생성 ========'
echo '======== [1-1] 클러스터 초기화 (Pod Network 세팅) ========'
kubeadm init --pod-network-cidr="$POD_NETWORK_CIDR" --apiserver-advertise-address "$MASTER_IP"

echo '======== [1-2] kubectl 사용 설정 ========'
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo "======== [1-3] Pod Network (Calico ${CALICO_VERSION}) 설치 ========"
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml

echo '======== [2] kubectl 편의기능 ========'
grep -q 'kubectl completion' ~/.bashrc || cat >> ~/.bashrc << 'EOF'
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF


echo ''
echo '============================================================'
echo '  클러스터 초기화 완료!'
echo '============================================================'
echo ''
if [ "$IS_VAGRANT" = true ]; then
  echo '  [Vagrant] Master IP: '$MASTER_IP
else
  echo '  [일반 서버] Master IP: '$MASTER_IP
fi
echo ''
echo '  [다음 단계]'
echo ''
echo '  1. 워커 조인 토큰 확인:'
echo '     kubeadm token create --print-join-command'
echo ''
echo '  2. 워커에서 각각 실행:'
echo '     sudo bash k8s-worker.sh "<위에서 출력된 join 명령어>"'
echo ''
echo '  3. 워커 조인 확인 (마스터에서):'
echo '     kubectl get nodes'
echo '     (모두 Ready 확인 후 다음 진행)'
echo ''
echo '  4. 스택 설치 (마스터에서):'
echo '     sudo bash k8s-master-apps.sh'
echo ''
echo '============================================================'
