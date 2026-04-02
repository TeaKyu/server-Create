#!/bin/bash
# k3s-common.sh
# K3s 설치 전 OS 기본 설정 스크립트
# K3s는 containerd를 내장하고 있으므로 별도 런타임 설치 불필요
# 사용법: sudo bash k3s-common.sh

set -e

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 구간 — 여기만 수정하세요 ★               │
# └─────────────────────────────────────────────────────────────┘

# 환경 선택
#   false = 일반 서버/VM (온프레미스, AWS, GCP 등) ← 기본값
#   true  = OCI (Oracle Cloud Infrastructure)
IS_OCI=false

MASTER_HOSTNAME="k3s-master"   # 호스트명 (OCI/일반 공통)

# ─── [일반 서버] IS_OCI=false 일 때만 사용 ───────────────────
# ※ 서버 NIC에 직접 할당된 고정 IP (k3s가 바인딩하는 실제 IP)
MASTER_IP="192.168.1.10"   # ← 마스터 노드의 실제 IP로 변경

# ─── [OCI] IS_OCI=true 일 때만 사용 ─────────────────────────
# ※ MASTER_IP(일반)과 PUBLIC_IP(OCI)는 다른 개념:
#   MASTER_IP  → NIC에 실제 존재, k3s가 직접 바인딩 가능한 IP
#   PUBLIC_IP  → OCI Internet Gateway의 NAT IP, NIC에 없음
#                k3s가 바인딩 불가 → --node-external-ip 로만 사용
#   PRIVATE_IP → OCI NIC 실제 IP (자동 감지, 수정 불필요)
PUBLIC_IP=""   # ← OCI 콘솔 → 인스턴스 → 공용 IP 주소에서 확인

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 끝 — 아래는 수정하지 마세요 ★            │
# └─────────────────────────────────────────────────────────────┘

# OCI: Private IP 자동 감지 + 입력값 검증
if [ "$IS_OCI" = true ]; then
  PRIVATE_IP=$(ip route get 8.8.8.8 | awk '{print $7; exit}')
  if [ -z "$PUBLIC_IP" ]; then
    echo ''
    echo '============================================================'
    echo '  [OCI] [오류] PUBLIC_IP가 설정되지 않았습니다!'
    echo '============================================================'
    echo '  OCI 콘솔 → 인스턴스 → 공용 IP 주소 확인 후'
    echo '  이 스크립트 상단의 PUBLIC_IP 변수에 입력하세요.'
    echo '============================================================'
    exit 1
  fi
  echo "  [OCI] Private IP (자동 감지): $PRIVATE_IP"
  echo "  [OCI] Public IP  (수동 입력): $PUBLIC_IP"
  echo ''
fi


echo '======== [0] Rocky Linux 9 기본 설정 ========'

echo '======== [0-1] root 비밀번호 설정 ========'
echo "root:1234" | chpasswd

echo '======== [0-2] 타임존 설정 및 동기화 ========'
timedatectl set-timezone Asia/Seoul
timedatectl set-ntp true
chronyc makestep

echo '======== [0-3] 기본 패키지 설치 ========'
if [ "$IS_OCI" = false ]; then
  # [일반 서버] 기본 패키지
  dnf install -y dnf-utils iproute-tc git curl
else
  # [OCI] iptables-services 추가 (REJECT 룰 영구 저장 용도)
  dnf install -y dnf-utils iproute-tc git curl iptables-services
fi

echo '======== [0-4] hosts 설정 ========'
if [ "$IS_OCI" = false ]; then
  # [일반 서버] 고정 IP → 호스트명 매핑
  grep -q "$MASTER_HOSTNAME" /etc/hosts || cat << EOF >> /etc/hosts
$MASTER_IP $MASTER_HOSTNAME
EOF
else
  # [OCI] Private IP → 호스트명 매핑 (NIC 실제 IP 기준)
  grep -q "$MASTER_HOSTNAME" /etc/hosts || cat << EOF >> /etc/hosts
$PRIVATE_IP $MASTER_HOSTNAME
EOF
fi

echo '======== [0-5] 방화벽 설정 ========'
if [ "$IS_OCI" = false ]; then
  # [일반 서버] firewalld만 비활성화
  systemctl stop firewalld && systemctl disable firewalld

else
  # ┌─────────────────────────────────────────────────────────┐
  # │ [OCI 전용] OCI 기본 이미지는 iptables REJECT 룰이 내장    │
  # │ firewalld 비활성화만으로는 부족하고,                      │
  # │ iptables INPUT 체인의 REJECT 룰도 반드시 제거해야 함      │
  # └─────────────────────────────────────────────────────────┘

  # 1) firewalld 비활성화
  systemctl stop firewalld && systemctl disable firewalld

  # 2) OCI 기본 iptables REJECT 룰 제거 및 정책 ACCEPT로 초기화
  iptables -P INPUT   ACCEPT
  iptables -P FORWARD ACCEPT
  iptables -P OUTPUT  ACCEPT
  iptables -F INPUT   # INPUT 체인 전체 flush (REJECT 룰 포함)

  # 3) 영구 저장 (재부팅 후에도 유지)
  iptables-save > /etc/sysconfig/iptables
  systemctl enable iptables

  # ─── 참고: OCI Security List에서도 인바운드 포트 허용 필요 ────
  # OCI 콘솔 → 네트워킹 → VCN → 서브넷 → Security List → Ingress Rules
  #   6443/tcp   - k3s API Server (kubectl 원격 접속)
  #   80/tcp     - HTTP Ingress/Gateway
  #   443/tcp    - HTTPS
  #   30080/tcp  - Envoy Gateway NodePort (HTTP)
  #   8472/udp   - Flannel VXLAN (멀티 노드 시)
  #   10250/tcp  - kubelet
  # ──────────────────────────────────────────────────────────────
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
# k3s-master.sh, k3s-apps.sh, k3s-worker.sh에서 공유
if [ "$IS_OCI" = false ]; then
  # [일반 서버] 고정 IP 저장
  cat > /etc/k3s-env << EOF
IS_OCI=false
MASTER_IP=$MASTER_IP
EOF
else
  # [OCI] Private/Public IP 저장
  cat > /etc/k3s-env << EOF
IS_OCI=true
PRIVATE_IP=$PRIVATE_IP
PUBLIC_IP=$PUBLIC_IP
EOF
fi


echo ''
echo '============================================================'
if [ "$IS_OCI" = false ]; then
  echo '  공통 설정 완료! [일반 서버]'
  echo ''
  echo '  Master IP: '$MASTER_IP
else
  echo '  공통 설정 완료! [OCI 환경]'
  echo ''
  echo '  Private IP (NIC): '$PRIVATE_IP
  echo '  Public IP  (NAT): '$PUBLIC_IP
  echo ''
  echo '  ★ OCI 콘솔 Security List에서 인바운드 허용 확인 필요!'
  echo '    6443/tcp  30080/tcp  8472/udp  10250/tcp'
fi
echo ''
echo '  [다음 단계]'
echo '  sudo bash k3s-master.sh'
echo ''
echo '============================================================'
