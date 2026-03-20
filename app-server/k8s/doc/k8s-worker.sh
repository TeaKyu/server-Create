#!/bin/bash
# k8s-worker.sh
# k8s-common.sh 실행 완료 후, Worker 노드에서만 실행
# 사용법: sudo bash k8s-worker.sh "<kubeadm join 명령어>"

set -e

if [ -z "$1" ]; then
  echo ''
  echo '사용법: sudo bash k8s-worker.sh "<kubeadm join 명령어>"'
  echo ''
  echo '마스터 노드에서 아래 명령어로 조인 토큰을 확인하세요:'
  echo '  kubeadm token create --print-join-command'
  echo ''
  echo '예시:'
  echo '  sudo bash k8s-worker.sh "kubeadm join 192.168.56.30:6443 --token abc123 --discovery-token-ca-cert-hash sha256:xxxx"'
  echo ''
  exit 1
fi

echo '======== Worker 노드 클러스터 조인 ========'
eval $1

echo ''
echo '======== Worker 노드 조인 완료 ========'
echo '마스터 노드에서 확인: kubectl get nodes'
