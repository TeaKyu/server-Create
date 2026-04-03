#!/bin/bash
# k8s-common.sh
# 모든 노드(master, worker1, worker2)에서 실행하는 공통 스크립트
# 사용법: sudo bash k8s-common.sh

set -e

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 구간 — 여기만 수정하세요 ★               │
# └─────────────────────────────────────────────────────────────┘

# 환경 선택
#   false = 일반 서버/VM (온프레미스, AWS, GCP 등) ← 기본값
#   true  = Vagrant (VirtualBox 로컬 개발 환경)
IS_VAGRANT=false

MASTER_HOSTNAME="k8s-master"

# Kubernetes 버전 (repo 및 설치에 사용)
K8S_VERSION="v1.34"

# ─── [일반 서버] IS_VAGRANT=false 일 때만 사용 ───────────────
# ※ 서버 NIC에 직접 할당된 고정 IP
MASTER_IP="192.168.1.10"          # ← 마스터 노드의 실제 IP로 변경
WORKER1_HOSTNAME="k8s-worker1"
WORKER1_IP="192.168.1.11"         # ← 워커1 IP (없으면 비워두기)
WORKER2_HOSTNAME="k8s-worker2"
WORKER2_IP="192.168.1.12"         # ← 워커2 IP (없으면 비워두기)

# ─── [Vagrant] IS_VAGRANT=true 일 때만 사용 ──────────────────
# ※ Vagrantfile에 정의된 IP와 일치해야 함 (기본값 수정 불필요)
VAGRANT_MASTER_IP="192.168.56.30"
VAGRANT_WORKER1_IP="192.168.56.31"
VAGRANT_WORKER2_IP="192.168.56.32"

# ┌─────────────────────────────────────────────────────────────┐
# │              ★ 설정 끝 — 아래는 수정하지 마세요 ★            │
# └─────────────────────────────────────────────────────────────┘

# Vagrant: 고정 IP로 덮어쓰기
if [ "$IS_VAGRANT" = true ]; then
  MASTER_IP="$VAGRANT_MASTER_IP"
  WORKER1_HOSTNAME="k8s-worker1"
  WORKER1_IP="$VAGRANT_WORKER1_IP"
  WORKER2_HOSTNAME="k8s-worker2"
  WORKER2_IP="$VAGRANT_WORKER2_IP"
  echo "  [Vagrant] Master IP:  $MASTER_IP"
  echo "  [Vagrant] Worker1 IP: $WORKER1_IP"
  echo "  [Vagrant] Worker2 IP: $WORKER2_IP"
  echo ''
else
  echo "  [일반 서버] Master IP:  $MASTER_IP"
  [ -n "$WORKER1_IP" ] && echo "  [일반 서버] Worker1 IP: $WORKER1_IP"
  [ -n "$WORKER2_IP" ] && echo "  [일반 서버] Worker2 IP: $WORKER2_IP"
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
dnf install -y dnf-utils iproute-tc git curl

echo '======== [0-4] hosts 설정 ========'
grep -q "$MASTER_HOSTNAME" /etc/hosts || cat << EOF >> /etc/hosts
$MASTER_IP $MASTER_HOSTNAME
EOF
if [ -n "$WORKER1_IP" ]; then
  grep -q "$WORKER1_HOSTNAME" /etc/hosts || echo "$WORKER1_IP $WORKER1_HOSTNAME" >> /etc/hosts
fi
if [ -n "$WORKER2_IP" ]; then
  grep -q "$WORKER2_HOSTNAME" /etc/hosts || echo "$WORKER2_IP $WORKER2_HOSTNAME" >> /etc/hosts
fi

echo '======== [0-5] 방화벽 해제 ========'
systemctl stop firewalld && systemctl disable firewalld

echo '======== [0-6] Swap 비활성화 ========'
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab

echo '======== [0-7] SELinux Permissive 설정 ========'
setenforce 0
sed -i 's/^SELINUX=enforcing$/SELINUX=permissive/' /etc/selinux/config


echo '======== [1] 컨테이너 런타임 설치 전 사전작업 ========'
echo '======== [1-1] iptables 세팅 ========'
cat <<EOF | tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

modprobe overlay
modprobe br_netfilter

cat <<EOF | tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF

sysctl --system


echo '======== [2] 컨테이너 런타임 (containerd) 설치 ========'
echo '======== [2-1] Docker repo 설정 ========'
dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo

echo '======== [2-2] containerd 설치 ========'
dnf install -y containerd.io
systemctl daemon-reload
systemctl enable --now containerd

echo '======== [2-3] cri 활성화 (cgroup: systemd) ========'
containerd config default > /etc/containerd/config.toml
sed -i 's/ SystemdCgroup = false/ SystemdCgroup = true/' /etc/containerd/config.toml
systemctl restart containerd


echo "======== [3] kubeadm 설치 (${K8S_VERSION}) ========"
echo "======== [3-1] Kubernetes repo 설정 (${K8S_VERSION}) ========"
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo '======== [3-2] kubelet, kubeadm, kubectl 설치 ========'
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet

echo '======== [3-3] 한글 설치 ========'
dnf install -y glibc-langpack-ko


echo '======== [4] 환경 변수 파일 저장 ========'
# k8s-master.sh, k8s-master-apps.sh, k8s-worker.sh에서 공유
cat > /etc/k8s-env << EOF
IS_VAGRANT=$IS_VAGRANT
MASTER_IP=$MASTER_IP
MASTER_HOSTNAME=$MASTER_HOSTNAME
WORKER1_HOSTNAME=$WORKER1_HOSTNAME
WORKER1_IP=$WORKER1_IP
WORKER2_HOSTNAME=$WORKER2_HOSTNAME
WORKER2_IP=$WORKER2_IP
EOF


echo ''
echo '============================================================'
if [ "$IS_VAGRANT" = true ]; then
  echo '  공통 설정 완료! [Vagrant 환경]'
  echo ''
  echo '  Master:  '$MASTER_IP' ('$MASTER_HOSTNAME')'
  echo '  Worker1: '$WORKER1_IP' ('$WORKER1_HOSTNAME')'
  echo '  Worker2: '$WORKER2_IP' ('$WORKER2_HOSTNAME')'
else
  echo '  공통 설정 완료! [일반 서버]'
  echo ''
  echo '  Master: '$MASTER_IP' ('$MASTER_HOSTNAME')'
  [ -n "$WORKER1_IP" ] && echo '  Worker1: '$WORKER1_IP' ('$WORKER1_HOSTNAME')'
  [ -n "$WORKER2_IP" ] && echo '  Worker2: '$WORKER2_IP' ('$WORKER2_HOSTNAME')'
fi
echo ''
echo '  Kubernetes: '$K8S_VERSION
echo ''
echo '  [다음 단계]'
echo '  Master → sudo bash k8s-master.sh'
echo '  Worker → (마스터 초기화 + 워커 조인 순서로 진행)'
echo ''
echo '============================================================'
