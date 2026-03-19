#!/bin/bash
# k8s-common.sh
# 모든 노드(master, worker1, worker2)에서 실행하는 공통 스크립트
# 사용법: sudo bash k8s-common.sh

set -e

echo '======== [0] Rocky Linux 9 기본 설정 ========'

echo '======== [0-1] root 비밀번호 설정 ========'
echo "root:1234" | chpasswd

echo '======== [0-2] 타임존 설정 및 동기화 ========'
timedatectl set-timezone Asia/Seoul
timedatectl set-ntp true
chronyc makestep

# generic/rocky9 box는 128GB LVM 동적 디스크이므로 확장 불필요
#echo '======== [0-3] Disk 확장 ========'
#dnf install -y cloud-utils-growpart
#growpart /dev/sda 4
#xfs_growfs /dev/sda4

echo '======== [0-4] 기본 패키지 설치 ========'
dnf install -y dnf-utils iproute-tc git

echo '======== [0-5] hosts 설정 ========'
cat << EOF >> /etc/hosts
192.168.56.30 k8s-master
192.168.56.31 k8s-worker1
192.168.56.32 k8s-worker2
EOF

echo '======== [0-6] 방화벽 해제 ========'
systemctl stop firewalld && systemctl disable firewalld

echo '======== [0-7] Swap 비활성화 ========'
swapoff -a && sed -i '/ swap / s/^/#/' /etc/fstab

echo '======== [0-8] SELinux Permissive 설정 ========'
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


echo '======== [3] kubeadm 설치 ========'
echo '======== [3-1] Kubernetes repo 설정 (v1.34) ========'
cat <<EOF | tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.34/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

echo '======== [3-2] kubelet, kubeadm, kubectl 설치 ========'
dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
systemctl enable --now kubelet

echo '======== [3-3] 한글 설치 ========'
dnf install -y glibc-langpack-ko

echo ''
echo '============================================================'
echo '  공통 설정 완료!'
echo '============================================================'
echo ''
echo '  [다음 단계]'
echo '  Master → sudo bash k8s-master.sh'
echo '  Worker → (마스터 초기화 + 워커 조인 순서로 진행)'
echo ''
echo '============================================================'
