#!/bin/bash
# k8s-worker.sh
# k8s-common.sh 실행 완료 후, Worker 노드에서만 실행
# 사용법: sudo bash k8s-worker.sh "<kubeadm join 명령어>"

set -e
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMMON_SCRIPT_PATH="${SCRIPT_DIR}/k8s-common.sh"

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

if [ -z "${1:-}" ]; then
  echo ''
  echo '사용법: sudo bash k8s-worker.sh "<kubeadm join 명령어>"'
  echo ''
  echo '마스터 노드에서 아래 명령어로 조인 토큰을 확인하세요:'
  echo '  kubeadm token create --print-join-command'
  echo ''
  echo '예시:'
  echo '  sudo bash k8s-worker.sh "kubeadm join <MASTER_IP>:6443 --token abc123 --discovery-token-ca-cert-hash sha256:xxxx"'
  echo ''
  exit 1
fi

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

if [ "$IS_VAGRANT" = true ]; then
  echo "  [Vagrant] Master IP: $MASTER_IP"
else
  echo "  [일반 서버] Master IP: $MASTER_IP"
fi
echo ''

echo '======== Worker 노드 클러스터 조인 ========'
if [[ "$1" != kubeadm\ join* ]]; then
  echo '[오류] kubeadm join 명령어만 허용됩니다.'
  exit 1
fi
eval "$1"

echo ''
echo '======== Worker 노드 조인 완료 ========'
echo '마스터 노드에서 확인: kubectl get nodes'
