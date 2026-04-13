#!/bin/bash
# k3s-common.sh
# K3s 설치 전 OS 기본 설정 스크립트
# 사용법: sudo bash k3s-common.sh

set -e

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 구간 — 여기만 수정하세요 ★               │
# └─────────────────────────────────────────────────────────────┘

# 네트워크 구조 선택
#   false = NAT 미사용 환경
#           예: 온프레미스, 사설망, 공인 IP가 NIC에 직접 붙는 VM
#   true  = NAT 사용 환경
#           예: VM은 private IP만 바인딩하고 외부 IP는 NAT로만 보이는 환경
USE_NAT=true

MASTER_HOSTNAME="k3s-master"

# ─── [NAT 미사용] USE_NAT=false 일 때만 사용 ─────────────────
# 서버 NIC에 직접 존재해서 k3s가 바인딩할 실제 IP
DIRECT_BIND_IP="192.168.1.10"

# ─── [NAT 사용] USE_NAT=true 일 때만 사용 ────────────────────
# EXTERNAL_IP는 나중에 알아도 됩니다.
# 비워두면 내부 통신/private IP 기준으로 먼저 설치하고,
# 외부 접속 설정은 나중에 추가 반영합니다.
EXTERNAL_IP=""

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 끝 — 아래는 수정하지 마세요 ★            │
# └─────────────────────────────────────────────────────────────┘

if [ "$USE_NAT" = true ]; then
  PRIVATE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
  echo "  [NAT 사용] Private IP (자동 감지): $PRIVATE_IP"
  if [ -n "$EXTERNAL_IP" ]; then
    echo "  [NAT 사용] External IP (수동 입력): $EXTERNAL_IP"
  else
    echo '  [NAT 사용] External IP: 아직 미확인'
    echo '  외부 API/브라우저 접속은 나중에 External IP 확인 후 반영하면 됩니다.'
  fi
  echo ''
fi

echo '======== [0] Rocky Linux 9 기본 설정 ========'

echo '======== [0-1] root 비밀번호 설정 ========'
echo "root:1234" | chpasswd

echo '======== [0-2] 타임존 설정 및 동기화 ========'
timedatectl set-timezone Asia/Seoul
# Rocky Linux 9는 systemd-timesyncd 대신 chronyd를 사용하므로
# rpm -q 로 패키지 설치 여부를 먼저 확인한다.
rpm -q chrony &>/dev/null || dnf install -y chrony
systemctl enable --now chronyd
chronyc makestep

echo '======== [0-3] 기본 패키지 설치 ========'
if [ "$USE_NAT" = false ]; then
  dnf install -y dnf-utils iproute-tc git curl
else
  dnf install -y dnf-utils iproute-tc git curl iptables-services
fi

echo '======== [0-4] hosts 설정 ========'
if [ "$USE_NAT" = false ]; then
  grep -q "$MASTER_HOSTNAME" /etc/hosts || cat << EOF >> /etc/hosts
$DIRECT_BIND_IP $MASTER_HOSTNAME
EOF
else
  grep -q "$MASTER_HOSTNAME" /etc/hosts || cat << EOF >> /etc/hosts
$PRIVATE_IP $MASTER_HOSTNAME
EOF
fi

echo '======== [0-5] 방화벽 설정 ========'
if [ "$USE_NAT" = false ]; then
  systemctl stop firewalld && systemctl disable firewalld
else
  systemctl stop firewalld && systemctl disable firewalld

  # NAT형 클라우드 이미지는 기본 REJECT 룰이 남아 있는 경우가 있어
  # NodePort, kubelet, VXLAN 통신이 막히지 않도록 초기화한다.
  iptables -P INPUT ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT ACCEPT
  iptables -F INPUT

  iptables-save > /etc/sysconfig/iptables
  systemctl enable iptables

  # 보안 그룹/보안 목록/방화벽 정책에서 아래 포트 허용 필요
  #   6443/tcp   - k3s API Server
  #   30080/tcp  - Envoy Gateway NodePort (HTTP)
  #   8472/udp   - Flannel VXLAN (멀티 노드 시)
  #   10250/tcp  - kubelet
fi

echo '======== [0-6] Swap 비활성화 ========'
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab

echo '======== [0-7] SELinux Permissive 설정 ========'
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config

echo '======== [1] iptables 모듈 세팅 ========'
cat <<EOF | tee /etc/modules-load.d/k3s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k3s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system

echo '======== [2] 한글 설치 ========'
dnf install -y glibc-langpack-ko

echo '======== [3] 환경 변수 파일 저장 ========'
if [ "$USE_NAT" = false ]; then
  cat > /etc/k3s-env << EOF
USE_NAT=false
MASTER_HOSTNAME=$MASTER_HOSTNAME
DIRECT_BIND_IP=$DIRECT_BIND_IP
EOF
else
  cat > /etc/k3s-env << EOF
USE_NAT=true
MASTER_HOSTNAME=$MASTER_HOSTNAME
PRIVATE_IP=$PRIVATE_IP
EXTERNAL_IP=$EXTERNAL_IP
EOF
fi

echo ''
echo '============================================================'
if [ "$USE_NAT" = false ]; then
  echo '  공통 설정 완료! [NAT 미사용]'
  echo ''
  echo '  Direct Bind IP: '$DIRECT_BIND_IP
else
  echo '  공통 설정 완료! [NAT 사용]'
  echo ''
  echo '  Private IP: '$PRIVATE_IP
  if [ -n "$EXTERNAL_IP" ]; then
    echo '  External IP: '$EXTERNAL_IP
  else
    echo '  External IP: 아직 미확인'
    echo '  내부 설치/내부 접속 기준으로 먼저 진행할 수 있습니다.'
  fi
  echo ''
  echo '  보안 그룹/보안 목록에서 6443/tcp 30080/tcp 8472/udp 10250/tcp 확인'
fi
echo ''
echo '  [다음 단계]'
echo '  sudo bash k3s-master.sh'
echo ''
echo '============================================================'
