#!/bin/bash
# k3s-worker.sh
# 워커 노드 전용 스크립트 — K3s Agent를 설치하여 클러스터에 조인
# 사전 조건: k3s-common.sh 실행 완료
# 사용 가이드: 06-워커-노드-확장-가이드.md 참고
# 사용법: sudo bash k3s-worker.sh

set -e

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 구간 — 여기만 수정하세요 ★               │
# └─────────────────────────────────────────────────────────────┘

# 마스터에서 토큰 확인: cat /var/lib/rancher/k3s/server/node-token
K3S_TOKEN=""   # ← 마스터 토큰 입력

# ─── [일반 서버] IS_OCI=false 일 때만 사용 ───────────────────
# ※ 마스터 NIC에 직접 할당된 고정 IP
MASTER_IP="192.168.1.10"   # ← 마스터 노드의 실제 IP로 변경

# ─── [OCI] IS_OCI=true 일 때만 사용 ─────────────────────────
# ※ 마스터의 Private IP (VCN 내부 통신, Public IP 아님)
#   마스터에서 확인: cat /etc/k3s-env | grep PRIVATE_IP
MASTER_PRIVATE_IP=""   # ← 마스터의 Private IP 입력

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 끝 — 아래는 수정하지 마세요 ★            │
# └─────────────────────────────────────────────────────────────┘

# ============================================================
# 환경 변수 로드 (k3s-common.sh에서 생성한 /etc/k3s-env 사용)
# ============================================================
if [ -f /etc/k3s-env ]; then
  source /etc/k3s-env
else
  echo '[오류] /etc/k3s-env 파일이 없습니다. k3s-common.sh를 먼저 실행하세요.'
  exit 1
fi


# ============================================================
# 입력값 유효성 확인
# ============================================================
if [ -z "$K3S_TOKEN" ]; then
  echo ''
  echo '============================================================'
  echo '  [오류] K3S_TOKEN이 설정되지 않았습니다!'
  echo '============================================================'
  echo '  1. 마스터 노드에서 토큰을 확인하세요:'
  echo '     cat /var/lib/rancher/k3s/server/node-token'
  echo '  2. 이 스크립트의 K3S_TOKEN 변수에 토큰을 넣고 다시 실행하세요.'
  echo '============================================================'
  exit 1
fi

if [ "$IS_OCI" = false ]; then
  if [ -z "$MASTER_IP" ]; then
    echo '[오류] MASTER_IP가 설정되지 않았습니다!'
    exit 1
  fi
  echo "  [일반 서버] 마스터 IP: $MASTER_IP"
else
  if [ -z "$MASTER_PRIVATE_IP" ]; then
    echo ''
    echo '============================================================'
    echo '  [OCI] [오류] MASTER_PRIVATE_IP가 설정되지 않았습니다!'
    echo '============================================================'
    echo '  마스터 노드의 Private IP를 입력하세요.'
    echo '  마스터에서 확인: cat /etc/k3s-env | grep PRIVATE_IP'
    echo '============================================================'
    exit 1
  fi
  echo "  [OCI] 마스터 Private IP:  $MASTER_PRIVATE_IP"
  echo "  [OCI] 워커  Private IP:   $PRIVATE_IP"
  echo "  [OCI] 워커  Public IP:    $PUBLIC_IP"
fi
echo ''


echo '======== [1] K3s Agent (워커) 설치 ========'

if [ "$IS_OCI" = false ]; then
  # ─────────────────────────────────────────────────────────────
  # [일반 서버] 마스터 고정 IP로 직접 조인
  # ─────────────────────────────────────────────────────────────
  curl -sfL https://get.k3s.io | \
    K3S_URL="https://${MASTER_IP}:6443" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -

else
  # ┌─────────────────────────────────────────────────────────┐
  # │ [OCI 전용] Private IP 기반 조인                          │
  # │                                                         │
  # │  K3S_URL        : 마스터의 Private IP로 접속            │
  # │                   (같은 VCN 내부 통신, Public IP 불가)   │
  # │  --node-ip      : 워커 자신의 Private IP                │
  # │                   (클러스터 내부 Pod 간 통신용)           │
  # │  --node-external-ip : 워커 자신의 Public IP             │
  # │                       (외부에서 노드 식별용)              │
  # └─────────────────────────────────────────────────────────┘
  curl -sfL https://get.k3s.io | \
    K3S_URL="https://${MASTER_PRIVATE_IP}:6443" \
    K3S_TOKEN="$K3S_TOKEN" \
    sh -s - agent \
      --node-ip          "$PRIVATE_IP" \
      --node-external-ip "$PUBLIC_IP"
fi

systemctl status k3s-agent --no-pager


echo ''
echo '============================================================'
echo '  K3s 워커 노드 조인 완료!'
echo '============================================================'
echo ''
if [ "$IS_OCI" = false ]; then
  echo '  [일반 서버]'
  echo "  마스터 IP: $MASTER_IP"
else
  echo '  [OCI]'
  echo "  마스터 Private IP: $MASTER_PRIVATE_IP"
  echo "  워커  Private IP:  $PRIVATE_IP"
  echo "  워커  Public IP:   $PUBLIC_IP"
fi
echo ''
echo '  마스터 노드에서 확인:'
echo '  kubectl get nodes -o wide'
echo ''
echo '============================================================'
