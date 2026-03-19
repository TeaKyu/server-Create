#!/bin/bash
# k8s-master.sh
# k8s-common.sh 실행 완료 후, Master 노드에서만 실행
# 이후 순서: 워커 조인 → k8s-master-apps.sh
# 사용법: sudo bash k8s-master.sh

set -e
export PATH=$PATH:/usr/local/bin

echo '======== [4] kubeadm 클러스터 생성 ========'
echo '======== [4-1] 클러스터 초기화 (Pod Network 세팅) ========'
kubeadm init --pod-network-cidr=20.96.0.0/12 --apiserver-advertise-address 192.168.56.30

echo '======== [4-2] kubectl 사용 설정 ========'
mkdir -p $HOME/.kube
cp -i /etc/kubernetes/admin.conf $HOME/.kube/config
chown $(id -u):$(id -g) $HOME/.kube/config

echo '======== [4-3] Pod Network (Calico v3.31) 설치 ========'
kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/v3.31.4/manifests/calico.yaml

echo '======== [5] kubectl 편의기능 ========'
echo "source <(kubectl completion bash)" >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc

echo ''
echo '============================================================'
echo '  클러스터 초기화 완료!'
echo '============================================================'
echo ''
echo '  [다음 단계]'
echo ''
echo '  1. 워커 조인 토큰 확인:'
echo '     kubeadm token create --print-join-command'
echo ''
echo '  2. 워커 2대에서 각각 실행:'
echo '     sudo bash k8s-worker.sh "<위에서 출력된 join 명령어>"'
echo ''
echo '  3. 워커 조인 확인 (마스터에서):'
echo '     kubectl get nodes'
echo '     (3대 모두 Ready 확인 후 다음 진행)'
echo ''
echo '  4. 스택 설치 (마스터에서):'
echo '     sudo bash k8s-master-apps.sh'
echo ''
echo '============================================================'
