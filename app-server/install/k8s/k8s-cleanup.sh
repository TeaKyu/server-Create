#!/bin/bash
# k8s-cleanup.sh
# 이 저장소로 설치한 kubeadm 기반 Kubernetes와 로컬 설정을 정리하는 스크립트
# 사용법:
#   sudo bash k8s-cleanup.sh
#   sudo bash k8s-cleanup.sh --yes
#   sudo bash k8s-cleanup.sh --remove-tools
#   sudo bash k8s-cleanup.sh --yes --remove-tools

set -euo pipefail

FORCE=false
REMOVE_TOOLS=false

DEFAULT_MASTER_HOSTNAME="k8s-master"
DEFAULT_WORKER1_HOSTNAME="k8s-worker1"
DEFAULT_WORKER2_HOSTNAME="k8s-worker2"

usage() {
  cat <<'EOF'
사용법:
  sudo bash k8s-cleanup.sh [--yes] [--remove-tools]

옵션:
  --yes, --force     확인 프롬프트 없이 바로 실행
  --remove-tools     /usr/local/bin/helm, /usr/local/bin/kubeseal 도 함께 삭제
  -h, --help         도움말 출력

설명:
  - 현재 노드의 kubeadm 기반 Kubernetes(control-plane 또는 worker)를 정리한다.
  - k8s-common.sh 가 만든 /etc/k8s-env, sysctl/modules 설정, hosts 항목을 정리한다.
  - kubelet, containerd 는 중지/비활성화하지만 패키지 자체는 삭제하지 않는다.
  - root 비밀번호, SELinux, firewalld, swap, timezone 같은 OS 설정은 자동 복구하지 않는다.

빠른 차이:
  - 기본 실행            : 삭제 전에 확인 질문을 한 번 묻는다.
  - --yes                : 확인 질문 없이 바로 진행한다.
  - --remove-tools       : helm, kubeseal 도 같이 삭제한다.
EOF
}

log() {
  echo "[k8s-cleanup] $1"
}

warn() {
  echo "[k8s-cleanup] 경고: $1"
}

cleanup_bashrc() {
  local target="$1"
  local tmp_file

  [ -f "$target" ] || return 0

  tmp_file=$(mktemp)
  awk '
    $0 != "source <(kubectl completion bash)" &&
    $0 != "alias k=kubectl" &&
    $0 != "complete -o default -F __start_kubectl k"
  ' "$target" > "$tmp_file"
  cat "$tmp_file" > "$target"
  rm -f "$tmp_file"
}

cleanup_kubeconfig() {
  local target="$1"

  [ -f "$target" ] || return 0

  if [ -f /etc/kubernetes/admin.conf ] && cmp -s "$target" /etc/kubernetes/admin.conf; then
    rm -f "$target"
    log "$target 제거"
    return 0
  fi

  warn "$target 는 현재 admin.conf 와 다를 수 있어 남겨둔다."
}

cleanup_hosts() {
  local tmp_file
  local backup_file

  [ -f /etc/hosts ] || return 0

  if ! grep -Eq "(^|[[:space:]])(${MASTER_HOSTNAME}|${WORKER1_HOSTNAME}|${WORKER2_HOSTNAME})([[:space:]]|$)" /etc/hosts; then
    return 0
  fi

  backup_file="/etc/hosts.k8s-cleanup.bak.$(date +%Y%m%d%H%M%S)"
  cp /etc/hosts "$backup_file"

  tmp_file=$(mktemp)
  awk -v h1="$MASTER_HOSTNAME" -v h2="$WORKER1_HOSTNAME" -v h3="$WORKER2_HOSTNAME" '
    $0 !~ "(^|[[:space:]])" h1 "([[:space:]]|$)" &&
    $0 !~ "(^|[[:space:]])" h2 "([[:space:]]|$)" &&
    $0 !~ "(^|[[:space:]])" h3 "([[:space:]]|$)" { print }
  ' /etc/hosts > "$tmp_file"
  cat "$tmp_file" > /etc/hosts
  rm -f "$tmp_file"

  log "/etc/hosts 에서 k8s 호스트 항목 제거, 백업 생성: $backup_file"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|--force|-y)
      FORCE=true
      ;;
    --remove-tools)
      REMOVE_TOOLS=true
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "알 수 없는 옵션: $1"
      usage
      exit 1
      ;;
  esac
  shift
done

if [ "${EUID}" -ne 0 ]; then
  echo 'root 권한으로 실행해야 한다. 예: sudo bash k8s-cleanup.sh'
  exit 1
fi

if [ -f /etc/k8s-env ]; then
  # shellcheck disable=SC1091
  source /etc/k8s-env
fi

MASTER_HOSTNAME="${MASTER_HOSTNAME:-$DEFAULT_MASTER_HOSTNAME}"
WORKER1_HOSTNAME="${WORKER1_HOSTNAME:-$DEFAULT_WORKER1_HOSTNAME}"
WORKER2_HOSTNAME="${WORKER2_HOSTNAME:-$DEFAULT_WORKER2_HOSTNAME}"

NODE_MODE="none"
if [ -f /etc/kubernetes/admin.conf ] || [ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]; then
  NODE_MODE="master"
elif [ -f /etc/kubernetes/kubelet.conf ] || [ -d /var/lib/kubelet ]; then
  NODE_MODE="worker"
fi

NODE_COUNT=""
if command -v kubectl >/dev/null 2>&1 && [ -f /etc/kubernetes/admin.conf ]; then
  export KUBECONFIG=/etc/kubernetes/admin.conf
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
fi

echo ''
echo '============================================================'
echo '  현재 노드의 kubeadm 기반 Kubernetes와 로컬 설정을 정리한다.'
echo "  감지된 노드 타입: $NODE_MODE"
if [ -f /etc/k8s-env ]; then
  echo "  IS_VAGRANT: ${IS_VAGRANT:-unknown}"
fi
if [ -n "$NODE_COUNT" ] && [ "$NODE_COUNT" -gt 1 ] 2>/dev/null; then
  warn "현재 클러스터 노드가 ${NODE_COUNT}개 보인다. 마스터에서 실행 중이라면 워커를 먼저 drain/delete 하는 게 맞다."
fi
if [ "$REMOVE_TOOLS" = true ]; then
  echo '  helm, kubeseal 도 함께 삭제한다.'
fi
echo '============================================================'
echo ''

if [ "$FORCE" = false ]; then
  read -r -p "계속할까? [y/N] " answer
  case "$answer" in
    y|Y|yes|YES)
      ;;
    *)
      echo '취소했다.'
      exit 0
      ;;
  esac
fi

cleanup_kubeconfig /root/.kube/config

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  user_home=$(getent passwd "${SUDO_USER}" | cut -d: -f6 || true)
  if [ -n "$user_home" ]; then
    cleanup_kubeconfig "$user_home/.kube/config"
  fi
fi

if command -v kubeadm >/dev/null 2>&1 && { [ -d /etc/kubernetes ] || [ -d /var/lib/kubelet ] || [ -d /etc/cni/net.d ]; }; then
  log 'kubeadm reset 시작'
  if ! kubeadm reset -f; then
    warn 'kubeadm reset 에 실패했다. 남은 파일 정리는 계속 진행한다.'
  fi
else
  warn 'kubeadm reset 대상이 없거나 kubeadm 명령을 찾지 못했다. 로컬 설정 정리만 진행한다.'
fi

for svc in kubelet containerd; do
  if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1; then
    systemctl disable --now "$svc" >/dev/null 2>&1 || true
  fi
done

log '로컬 설정 파일 정리'
rm -f /etc/k8s-env
rm -f /etc/modules-load.d/k8s.conf
rm -f /etc/sysctl.d/k8s.conf
rm -f /etc/yum.repos.d/kubernetes.repo
rm -f /etc/containerd/config.toml

rm -rf /etc/cni/net.d
rm -rf /etc/kubernetes
rm -rf /var/lib/cni
rm -rf /var/lib/kubelet
rm -rf /var/lib/etcd
rm -rf /var/lib/calico
rm -rf /run/calico
rm -rf /var/run/calico

sysctl --system >/dev/null 2>&1 || true

cleanup_hosts
cleanup_bashrc /root/.bashrc

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  if [ -z "${user_home:-}" ]; then
    user_home=$(getent passwd "${SUDO_USER}" | cut -d: -f6 || true)
  fi
  if [ -n "${user_home:-}" ]; then
    cleanup_bashrc "$user_home/.bashrc"
  fi
fi

if [ "$REMOVE_TOOLS" = true ]; then
  log 'helm, kubeseal 삭제'
  rm -f /usr/local/bin/helm
  rm -f /usr/local/bin/kubeseal
fi

echo ''
echo '============================================================'
echo '  kubeadm 기반 Kubernetes 정리 완료'
echo '============================================================'
echo ''
echo '  자동으로 되돌리지 않은 항목:'
echo '  - root 비밀번호'
echo '  - SELinux 설정'
echo '  - firewalld 상태'
echo '  - swap 비활성화'
echo '  - timezone / locale'
echo '  - containerd, kubelet, kubeadm, kubectl 패키지 설치 여부'
echo ''
echo '  재설치할 때는:'
echo '  Master → sudo bash k8s-master.sh'
echo '  Worker → sudo bash k8s-worker.sh "<kubeadm join 명령어>"'
echo ''
echo '============================================================'
