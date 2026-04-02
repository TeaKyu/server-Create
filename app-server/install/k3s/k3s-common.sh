#!/bin/bash
# k3s-common.sh
# K3s 설치 전 OS 기본 설정 스크립트 (마스터 노드에서 실행)
# K3s는 containerd를 내장하고 있으므로 별도 런타임 설치 불필요
# 사용법: sudo bash k3s-common.sh

set -e

# ============================================================
# 환경 변수 (서버 환경에 맞게 수정)
# ============================================================
MASTER_IP="192.168.1.10"
MASTER_HOSTNAME="k3s-master"


echo '======== [0] Rocky Linux 9 기본 설정 ========'

echo '======== [0-1] root 비밀번호 설정 ========'
echo "root:1234" | chpasswd

echo '======== [0-2] 타임존 설정 및 동기화 ========'
timedatectl set-timezone Asia/Seoul
timedatectl set-ntp true
chronyc makestep

echo '======== [0-3] 기본 패키지 설치 ========'
dnf install -y dnf-utils iproute-tc git curl

echo '======== [0-4] hosts 설정 ========'
grep -q "$MASTER_HOSTNAME" /etc/hosts || cat << EOF >> /etc/hosts
$MASTER_IP $MASTER_HOSTNAME
EOF

echo '======== [0-5] 방화벽 해제 ========'
systemctl stop firewalld && systemctl disable firewalld

echo '======== [0-6] Swap 비활성화 ========'
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab

echo '======== [0-7] SELinux Permissive 설정 ========'
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config


echo '======== [1] iptables 세팅 ========'
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

echo ''
echo '============================================================'
echo '  공통 설정 완료!'
echo '============================================================'
echo ''
echo '  [다음 단계]'
echo '  sudo bash k3s-master.sh'
echo ''
echo '============================================================'
