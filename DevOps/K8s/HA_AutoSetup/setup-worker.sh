#!/usr/bin/env bash
# setup-worker.sh — interactive, narrated worker-node setup.
# Run via:  curl -fsSL <URL>/setup-worker.sh | bash
set -euo pipefail

c(){ printf '\033[%sm' "$1"; }
BLU=$(c '1;36'); GRN=$(c '1;32'); YLW=$(c '0;33'); RED=$(c '1;31'); BLD=$(c '1'); RST=$(c '0')
STAGE=0
stage(){ STAGE=$((STAGE+1)); printf '\n%s== Stage %s: %s ==%s\n' "$BLU$BLD" "$STAGE" "$*" "$RST"; }
info(){ printf '   %s\n' "$*"; }
run(){ printf '   %s$ %s%s\n' "$GRN" "$*" "$RST"; eval "$@"; }
ok(){ printf '   %s\xe2\x9c\x93 %s%s\n' "$GRN" "$*" "$RST"; }
warn(){ printf '   %s! %s%s\n' "$YLW" "$*" "$RST"; }
die(){ printf '%s\xe2\x9c\x97 %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }
ask(){ local p="$1" d="${2:-}" a; if [ -n "$d" ]; then printf '%s [%s]: ' "$p" "$d" >/dev/tty; else printf '%s: ' "$p" >/dev/tty; fi; IFS= read -r a </dev/tty || true; printf '%s' "${a:-$d}"; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

printf '%s\n' "${BLU}${BLD}Kubernetes — Worker Node Setup${RST}"
echo "Prepares this machine and joins it to the cluster as a worker."
echo

stage "Gathering settings"
K8S=$(ask "Kubernetes version (minor)" "v1.36")

stage "Disabling swap"
run "$SUDO swapoff -a"
run "$SUDO sed -i '/\\sswap\\s/ s/^/#/' /etc/fstab"

stage "Loading kernel modules and network settings"
printf 'overlay\nbr_netfilter\n' | $SUDO tee /etc/modules-load.d/k8s.conf >/dev/null
run "$SUDO modprobe overlay"
run "$SUDO modprobe br_netfilter"
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' | $SUDO tee /etc/sysctl.d/k8s.conf >/dev/null
run "$SUDO sysctl --system >/dev/null"

stage "Installing and configuring containerd"
run "$SUDO apt-get update -y -q"
run "$SUDO apt-get install -y -q containerd"
run "$SUDO mkdir -p /etc/containerd"
containerd config default | $SUDO tee /etc/containerd/config.toml >/dev/null
run "$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"
run "$SUDO systemctl restart containerd"
run "$SUDO systemctl enable containerd >/dev/null 2>&1"

stage "Installing kubeadm, kubelet and kubectl ($K8S)"
run "$SUDO apt-get install -y -q apt-transport-https ca-certificates curl gpg"
run "$SUDO mkdir -p /etc/apt/keyrings"
run "curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S/deb/Release.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S/deb/ /" | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
run "$SUDO apt-get update -y -q"
run "$SUDO apt-get install -y -q kubelet kubeadm kubectl"
run "$SUDO apt-mark hold kubelet kubeadm kubectl"

stage "Joining the cluster"
DEF=""
if [ -f /vagrant/join-commands.txt ]; then . /vagrant/join-commands.txt 2>/dev/null || true; DEF="${WORKER_JOIN:-}"; fi
info "Paste the WORKER join command from the first control plane"
info "(the shorter one, WITHOUT --control-plane). On a control plane you can"
info "regenerate it with:  kubeadm token create --print-join-command"
JOIN=$(ask "Worker join command" "$DEF")
[ -n "$JOIN" ] || die "No join command provided."
case "$JOIN" in *--control-plane*) die "That is a CONTROL-PLANE join — use the shorter worker command instead.";; esac
run "$JOIN"

echo
ok "${BLD}Worker joined.${RST}  Verify on a control plane with:  kubectl get nodes -o wide"
