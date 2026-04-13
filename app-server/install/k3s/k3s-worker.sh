#!/bin/bash
# k3s-worker.sh
# 워커 노드 전용 스크립트
# 사용법: sudo bash k3s-worker.sh

set -e

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 구간 — 여기만 수정하세요 ★               │
# └─────────────────────────────────────────────────────────────┘

K3S_TOKEN=""

# ─── [NAT 미사용] USE_NAT=false 일 때만 사용 ─────────────────
MASTER_DIRECT_IP="192.168.1.10"

# ─── [NAT 사용] USE_NAT=true 일 때만 사용 ────────────────────
# 워커는 마스터 private IP로 조인합니다.
MASTER_PRIVATE_IP=""

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 끝 — 아래는 수정하지 마세요 ★            │
# └─────────────────────────────────────────────────────────────┘

if [ -f /etc/k3s-env ]; then
  source /etc/k3s-env
else
  echo '[오류] /etc/k3s-env 파일이 없습니다. k3s-common.sh를 먼저 실행하세요.'
  exit 1
fi

if [ -z "$K3S_TOKEN" ]; then
  echo ''
  echo '============================================================'
  echo '  [오류] K3S_TOKEN이 설정되지 않았습니다!'
  echo '============================================================'
  echo '  마스터 노드에서 아래 명령으로 토큰을 확인하세요.'
  echo '  cat /var/lib/rancher/k3s/server/node-token'
  echo '============================================================'
  exit 1
fi

if [ "$USE_NAT" = false ]; then
  if [ -z "$MASTER_DIRECT_IP" ]; then
    echo '[오류] MASTER_DIRECT_IP가 설정되지 않았습니다!'
    exit 1
  fi
  echo "  [NAT 미사용] 마스터 IP: $MASTER_DIRECT_IP"
else
  if [ -z "$MASTER_PRIVATE_IP" ]; then
    echo ''
    echo '============================================================'
    echo '  [오류] MASTER_PRIVATE_IP가 설정되지 않았습니다!'
    echo '============================================================'
    echo '  마스터 노드의 private IP를 입력하세요.'
    echo '  마스터에서 확인: cat /etc/k3s-env | grep PRIVATE_IP'
    echo '============================================================'
    exit 1
  fi
  echo "  [NAT 사용] 마스터 Private IP: $MASTER_PRIVATE_IP"
  echo "  [NAT 사용] 워커  Private IP:  $PRIVATE_IP"
  if [ -n "$EXTERNAL_IP" ]; then
    echo "  [NAT 사용] 워커  External IP: $EXTERNAL_IP"
  else
    echo '  [NAT 사용] 워커  External IP: 아직 미확인'
  fi
fi
echo ''

echo '======== [1] K3s Agent (워커) 설치 ========'

if [ "$USE_NAT" = false ]; then
  curl -sfL https://get.k3s.io | \
    K3S_URL="https://${MASTER_DIRECT_IP}:6443" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -
else
  set -- agent --node-ip "$PRIVATE_IP"
  if [ -n "$EXTERNAL_IP" ]; then
    set -- "$@" --node-external-ip "$EXTERNAL_IP"
  fi

  curl -sfL https://get.k3s.io | \
    K3S_URL="https://${MASTER_PRIVATE_IP}:6443" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -s - "$@"
fi

systemctl status k3s-agent --no-pager

echo ''
echo '============================================================'
echo '  K3s 워커 노드 조인 완료!'
echo '============================================================'
echo ''
if [ "$USE_NAT" = false ]; then
  echo "  마스터 IP: $MASTER_DIRECT_IP"
else
  echo "  마스터 Private IP: $MASTER_PRIVATE_IP"
  echo "  워커  Private IP:  $PRIVATE_IP"
  if [ -n "$EXTERNAL_IP" ]; then
    echo "  워커  External IP: $EXTERNAL_IP"
  else
    echo '  워커  External IP: 아직 미확인'
  fi
fi
echo ''
echo '  마스터 노드에서 확인:'
echo '  kubectl get nodes -o wide'
echo ''
echo '============================================================'
