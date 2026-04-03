#!/bin/bash
# k8s-worker.sh
# k8s-common.sh 실행 완료 후, Worker 노드에서만 실행
# 사용법: sudo bash k8s-worker.sh "<kubeadm join 명령어>"

set -e

# ============================================================
# 환경 변수 로드 (k8s-common.sh에서 생성한 /etc/k8s-env 사용)
# ============================================================
if [ -f /etc/k8s-env ]; then
  source /etc/k8s-env
else
  echo '[오류] /etc/k8s-env 파일이 없습니다. k8s-common.sh를 먼저 실행하세요.'
  exit 1
fi

if [ -z "$1" ]; then
  echo ''
  echo '사용법: sudo bash k8s-worker.sh "<kubeadm join 명령어>"'
  echo ''
  echo '마스터 노드에서 아래 명령어로 조인 토큰을 확인하세요:'
  echo '  kubeadm token create --print-join-command'
  echo ''
  echo '예시:'
  echo "  sudo bash k8s-worker.sh \"kubeadm join ${MASTER_IP}:6443 --token abc123 --discovery-token-ca-cert-hash sha256:xxxx\""
  echo ''
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
