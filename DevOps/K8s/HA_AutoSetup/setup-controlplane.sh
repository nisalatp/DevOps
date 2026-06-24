#!/usr/bin/env bash
# setup-controlplane.sh — interactive, narrated control-plane setup.
# Safe to run via:  curl -fsSL <URL>/setup-controlplane.sh | bash
# (prompts are read from /dev/tty so piping from curl still works).
set -euo pipefail

# ---------- pretty output helpers ----------
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
confirm(){ local a; a=$(ask "$1 (y/n)" "${2:-y}"); case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

printf '%s\n' "${BLU}${BLD}Kubernetes — Control-Plane Setup${RST}"
echo "This will prepare this machine and either start a new cluster or add this"
echo "node to an existing control plane. It explains each stage as it goes."
echo

# ---------- Stage 0: gather inputs ----------
stage "Gathering settings"
NODE_IP_DEFAULT=$(hostname -I | tr ' ' '\n' | grep -vE '^(10\.0\.2\.|127\.|169\.254\.)' | head -1 || true)
ENDPOINT=$(ask "Control-plane endpoint (the load-balancer VIP, host:port)" "k8s-vip:6443")
NODE_IP=$(ask "This node's cluster IP (advertised to the cluster)" "${NODE_IP_DEFAULT:-}")
K8S=$(ask "Kubernetes version (minor)" "v1.36")
POD_CIDR=$(ask "Pod network CIDR (must not overlap your subnet)" "10.244.0.0/16")
CALICO=$(ask "Calico version" "v3.29.1")
[ -n "$NODE_IP" ] || die "Could not determine this node's IP — re-run and enter it."
if confirm "Is this the FIRST control plane (initialise a brand-new cluster)?"; then FIRST=yes; else FIRST=no; fi
info "Endpoint=${ENDPOINT}  Node IP=${NODE_IP}  K8s=${K8S}  First=${FIRST}"

# ---------- Stage 1: disable swap ----------
stage "Disabling swap (required by the kubelet)"
run "$SUDO swapoff -a"
run "$SUDO sed -i '/\\sswap\\s/ s/^/#/' /etc/fstab"
ok "Swap is off."

# ---------- Stage 2: kernel modules & sysctl ----------
stage "Loading kernel modules and network settings"
info "Writing /etc/modules-load.d/k8s.conf (overlay, br_netfilter)"
printf 'overlay\nbr_netfilter\n' | $SUDO tee /etc/modules-load.d/k8s.conf >/dev/null
run "$SUDO modprobe overlay"
run "$SUDO modprobe br_netfilter"
info "Writing /etc/sysctl.d/k8s.conf (ip_forward, bridge-nf-call-iptables)"
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' | $SUDO tee /etc/sysctl.d/k8s.conf >/dev/null
run "$SUDO sysctl --system >/dev/null"
ok "Kernel ready for container networking."

# ---------- Stage 3: container runtime ----------
stage "Installing and configuring containerd"
run "$SUDO apt-get update -y -q"
run "$SUDO apt-get install -y -q containerd"
run "$SUDO mkdir -p /etc/containerd"
info "Generating default config and enabling the systemd cgroup driver"
containerd config default | $SUDO tee /etc/containerd/config.toml >/dev/null
run "$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"
run "$SUDO systemctl restart containerd"
run "$SUDO systemctl enable containerd >/dev/null 2>&1"
ok "containerd is running with SystemdCgroup=true."

# ---------- Stage 4: install kube tools ----------
stage "Installing kubeadm, kubelet and kubectl ($K8S)"
run "$SUDO apt-get install -y -q apt-transport-https ca-certificates curl gpg"
run "$SUDO mkdir -p /etc/apt/keyrings"
run "curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S/deb/Release.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S/deb/ /" | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null
run "$SUDO apt-get update -y -q"
run "$SUDO apt-get install -y -q kubelet kubeadm kubectl"
run "$SUDO apt-mark hold kubelet kubeadm kubectl"
ok "Kubernetes tools installed and held."

if [ "$FIRST" = "yes" ]; then
  # ---------- Stage 5: kubeadm init ----------
  stage "Initialising the control plane (kubeadm init)"
  info "Using --control-plane-endpoint=$ENDPOINT so every node reaches the API via the load balancer."
  run "$SUDO kubeadm init --control-plane-endpoint '$ENDPOINT' --upload-certs --pod-network-cidr='$POD_CIDR' --apiserver-advertise-address='$NODE_IP'"

  # ---------- Stage 6: kubectl config ----------
  stage "Configuring kubectl for $(whoami)"
  run "mkdir -p \$HOME/.kube"
  run "$SUDO cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config"
  run "$SUDO chown \$(id -u):\$(id -g) \$HOME/.kube/config"
  ok "kubectl is ready (try: kubectl get nodes)."

  # ---------- Stage 7: Calico ----------
  stage "Installing the Calico pod network ($CALICO)"
  run "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/tigera-operator.yaml"
  info "Creating an IP pool that matches $POD_CIDR (VXLAN encapsulation)"
  cat <<EOF | kubectl create -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - name: default-ipv4-ippool
      cidr: ${POD_CIDR}
      encapsulation: VXLAN
EOF
  ok "Calico is installing. Nodes turn Ready once its pods are Running."

  # ---------- Stage 8: join commands ----------
  stage "Generating the join commands for the other nodes"
  WJOIN="sudo $(kubeadm token create --print-join-command)"
  CKEY=$($SUDO kubeadm init phase upload-certs --upload-certs | tail -n1)
  CPJOIN="$WJOIN --control-plane --certificate-key $CKEY"
  echo
  info "${BLD}CONTROL-PLANE join (run on the other control planes):${RST}"
  echo "      $CPJOIN"
  echo
  info "${BLD}WORKER join (run on each worker):${RST}"
  echo "      $WJOIN"
  echo
  if [ -d /vagrant ]; then
    printf 'WORKER_JOIN=%q\nCP_JOIN=%q\n' "$WJOIN" "$CPJOIN" | $SUDO tee /vagrant/join-commands.txt >/dev/null
    ok "Saved both commands to /vagrant/join-commands.txt — the other scripts read it automatically."
  else
    warn "Copy the two commands above; you'll paste them on the other nodes."
  fi
else
  # ---------- Stage 5: join as an additional control plane ----------
  stage "Joining this node as an ADDITIONAL control plane"
  DEF=""
  if [ -f /vagrant/join-commands.txt ]; then . /vagrant/join-commands.txt 2>/dev/null || true; DEF="${CP_JOIN:-}"; fi
  info "Paste the CONTROL-PLANE join command from the first control plane"
  info "(the long one ending in --control-plane --certificate-key)."
  JOIN=$(ask "Control-plane join command" "$DEF")
  [ -n "$JOIN" ] || die "No join command provided."
  case "$JOIN" in *--control-plane*) : ;; *) warn "That doesn't look like a control-plane join (missing --control-plane)."; esac
  run "$JOIN $([ -n "$NODE_IP" ] && echo --apiserver-advertise-address=$NODE_IP)"
  stage "Configuring kubectl for $(whoami)"
  run "mkdir -p \$HOME/.kube"
  run "$SUDO cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config"
  run "$SUDO chown \$(id -u):\$(id -g) \$HOME/.kube/config"
fi

echo
ok "${BLD}Control-plane node is set up.${RST}"
info "Check progress with:  kubectl get nodes   and   kubectl get pods -A"
