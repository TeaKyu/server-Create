#!/bin/bash
# k3s-cleanup.sh
# 이 저장소로 설치한 K3s와 로컬 설정을 정리하는 스크립트
# 사용법:
#   sudo bash k3s-cleanup.sh
#   sudo bash k3s-cleanup.sh --yes
#   sudo bash k3s-cleanup.sh --remove-tools
#   sudo bash k3s-cleanup.sh --yes --remove-tools

set -euo pipefail

FORCE=false
REMOVE_TOOLS=false

usage() {
  cat <<'EOF'
사용법:
  sudo bash k3s-cleanup.sh [--yes] [--remove-tools]

옵션:
  --yes, --force     확인 프롬프트 없이 바로 실행
  --remove-tools     /usr/local/bin/helm, /usr/local/bin/kubeseal 도 함께 삭제
  -h, --help         도움말 출력

설명:
  - 현재 노드의 K3s(server 또는 agent)를 제거한다.
  - k3s-common.sh 가 만든 /etc/k3s-env, sysctl/modules 설정, hosts 항목을 정리한다.
  - root 비밀번호, SELinux, firewalld, timezone 같은 OS 설정은 자동 복구하지 않는다.

빠른 차이:
  - 기본 실행            : 삭제 전에 확인 질문을 한 번 묻는다.
  - --yes                : 확인 질문 없이 바로 진행한다.
  - --remove-tools       : helm, kubeseal 도 같이 삭제한다.
EOF
}

log() {
  echo "[k3s-cleanup] $1"
}

warn() {
  echo "[k3s-cleanup] 경고: $1"
}

cleanup_bashrc() {
  local target="$1"
  local tmp_file

  [ -f "$target" ] || return 0

  tmp_file=$(mktemp)
  awk '
    $0 != "export KUBECONFIG=/etc/rancher/k3s/k3s.yaml" &&
    $0 != "source <(kubectl completion bash)" &&
    $0 != "alias k=kubectl" &&
    $0 != "complete -o default -F __start_kubectl k"
  ' "$target" > "$tmp_file"
  cat "$tmp_file" > "$target"
  rm -f "$tmp_file"
}

cleanup_hosts() {
  local tmp_file
  local backup_file

  [ -f /etc/hosts ] || return 0

  if ! grep -Eq '(^|[[:space:]])k3s-master([[:space:]]|$)' /etc/hosts; then
    return 0
  fi

  backup_file="/etc/hosts.k3s-cleanup.bak.$(date +%Y%m%d%H%M%S)"
  cp /etc/hosts "$backup_file"

  tmp_file=$(mktemp)
  awk '$0 !~ /(^|[[:space:]])k3s-master([[:space:]]|$)/ { print }' /etc/hosts > "$tmp_file"
  cat "$tmp_file" > /etc/hosts
  rm -f "$tmp_file"

  log "/etc/hosts 에서 k3s-master 항목 제거, 백업 생성: $backup_file"
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
  echo 'root 권한으로 실행해야 한다. 예: sudo bash k3s-cleanup.sh'
  exit 1
fi

if [ -f /etc/k3s-env ]; then
  # shellcheck disable=SC1091
  source /etc/k3s-env
fi

NODE_MODE="none"
if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
  NODE_MODE="server"
elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
  NODE_MODE="agent"
fi

NODE_COUNT=""
if command -v kubectl >/dev/null 2>&1 && [ -f /etc/rancher/k3s/k3s.yaml ]; then
  export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
  NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ' || true)
fi

echo ''
echo '============================================================'
echo '  현재 노드의 K3s와 로컬 설정을 정리한다.'
echo "  감지된 노드 타입: $NODE_MODE"
if [ -n "${USE_NAT:-}" ]; then
  echo "  USE_NAT: $USE_NAT"
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

case "$NODE_MODE" in
  server)
    log 'k3s server 제거 시작'
    /usr/local/bin/k3s-uninstall.sh
    ;;
  agent)
    log 'k3s agent 제거 시작'
    /usr/local/bin/k3s-agent-uninstall.sh
    ;;
  *)
    warn 'k3s uninstall 스크립트를 찾지 못했다. 로컬 설정 정리만 진행한다.'
    ;;
esac

log '로컬 설정 파일 정리'
rm -f /etc/k3s-env
rm -f /etc/modules-load.d/k3s.conf
rm -f /etc/sysctl.d/k3s.conf
rm -f /etc/sysconfig/iptables
rm -f /usr/local/bin/k3s
rm -f /usr/local/bin/k3s-killall.sh
rm -f /usr/local/bin/k3s-uninstall.sh
rm -f /usr/local/bin/k3s-agent-uninstall.sh

rm -rf /etc/rancher
rm -rf /var/lib/rancher
rm -rf /var/lib/kubelet
rm -rf /var/lib/cni
rm -rf /etc/cni
rm -rf /run/k3s
rm -rf /run/flannel

sysctl --system >/dev/null 2>&1 || true

if systemctl list-unit-files iptables.service >/dev/null 2>&1; then
  systemctl disable --now iptables >/dev/null 2>&1 || true
fi

cleanup_hosts
cleanup_bashrc /root/.bashrc

if [ -n "${SUDO_USER:-}" ] && [ "${SUDO_USER}" != "root" ]; then
  user_home=$(getent passwd "${SUDO_USER}" | cut -d: -f6 || true)
  if [ -n "$user_home" ]; then
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
echo '  K3s 정리 완료'
echo '============================================================'
echo ''
echo '  자동으로 되돌리지 않은 항목:'
echo '  - root 비밀번호'
echo '  - SELinux 설정'
echo '  - firewalld 상태'
echo '  - timezone / locale'
echo ''
echo '  필요하면 수동으로 점검:'
echo '  systemctl status firewalld'
echo '  getenforce'
echo ''
echo '============================================================'
