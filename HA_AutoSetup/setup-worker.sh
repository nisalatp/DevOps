#!/usr/bin/env bash
# =============================================================================
# setup-worker.sh — Interactive, Narrated Worker Node Setup
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Prepares a Linux machine to become a Kubernetes WORKER node and joins it
#   to an existing cluster. A worker node runs your application containers
#   (Pods) but does NOT run control-plane components (API server, etcd, etc.).
#
# WHAT IS A WORKER NODE?
#   Workers are the "muscles" of the cluster. They:
#     - Run the kubelet (node agent) which manages Pods on this machine
#     - Run kube-proxy (network proxy) which implements Service networking
#     - Run containerd (container runtime) which actually runs containers
#     - Execute whatever workloads the scheduler assigns to them
#
#   In production, you typically have many more workers than control planes
#   (e.g., 3 control planes + 50 workers).
#
# HOW TO RUN:
#   Option A (Vagrant): vagrant ssh k8s-w1, then run this script.
#   Option B (curl):    curl -fsSL http://<host-ip>:8000/setup-worker.sh | bash
#   (Prompts are read from /dev/tty so piping from curl still works.)
#
# WHAT YOU'LL LEARN:
#   - The worker setup is almost identical to the control-plane setup
#     (same runtime, same packages) — the difference is "kubeadm join"
#     instead of "kubeadm init", and no --control-plane flag.
# =============================================================================

# ---- Shell safety settings ----
# -e  = exit immediately if ANY command fails
# -u  = treat unset variables as errors (catches typos)
# -o pipefail = if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# ---- Define colour codes for pretty terminal output ----
# c() generates ANSI escape sequences for terminal colours/formatting.
c(){ printf '\033[%sm' "$1"; }
BLU=$(c '1;36')   # Bold Cyan    — stage headings
GRN=$(c '1;32')   # Bold Green   — success messages and command echo
YLW=$(c '0;33')   # Yellow       — warnings
RED=$(c '1;31')   # Bold Red     — fatal errors
BLD=$(c '1')      # Bold (white) — emphasis
RST=$(c '0')      # Reset        — back to normal text

# ---- Stage counter ----
# Numbers each major step so students can follow along.
STAGE=0

# ---- Helper functions ----

# stage() — prints a numbered, coloured heading for each major step.
stage(){ STAGE=$((STAGE+1)); printf '\n%s== Stage %s: %s ==%s\n' "$BLU$BLD" "$STAGE" "$*" "$RST"; }

# info() — prints an indented informational line.
info(){ printf '   %s\n' "$*"; }

# run() — prints the command in green, then executes it.
# This lets students see exactly which command is being run.
run(){ printf '   %s$ %s%s\n' "$GRN" "$*" "$RST"; eval "$@"; }

# ok() — prints a green checkmark (✓) with a success message.
ok(){ printf '   %s\xe2\x9c\x93 %s%s\n' "$GRN" "$*" "$RST"; }

# warn() — prints a yellow warning message with "!" prefix.
warn(){ printf '   %s! %s%s\n' "$YLW" "$*" "$RST"; }

# die() — prints a red error (✗) to stderr and exits with failure.
die(){ printf '%s\xe2\x9c\x97 %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

# ask() — prompts for input with an optional default. Reads from /dev/tty
# so it works even when the script is piped from curl.
ask(){
  local p="$1" d="${2:-}" a           # p=prompt, d=default, a=answer
  if [ -n "$d" ]; then                # If a default was provided...
    printf '%s [%s]: ' "$p" "$d" >/dev/tty   # Show "Prompt [default]: "
  else
    printf '%s: ' "$p" >/dev/tty             # Show "Prompt: " (no default)
  fi
  IFS= read -r a </dev/tty || true   # Read input from the terminal
  printf '%s' "${a:-$d}"              # Output the answer (or default if blank)
}

# ---- Detect if we need sudo ----
# id -u returns the current user's numeric ID. Root is always 0.
# If we're not root, we prefix privileged commands with "sudo".
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# =============================================================================
# TITLE BANNER
# =============================================================================
printf '%s\n' "${BLU}${BLD}Kubernetes — Worker Node Setup${RST}"
echo "Prepares this machine and joins it to the cluster as a worker."
echo   # Blank line for spacing

# =============================================================================
# STAGE 1: Gather settings
# =============================================================================
# Workers need very little configuration — just the Kubernetes version
# (to install the right packages) and a join command.
stage "Gathering settings"

# Kubernetes version — determines which apt repository to use.
# Must match the version used by the control planes.
K8S=$(ask "Kubernetes version (minor)" "v1.36")

# =============================================================================
# STAGE 2: Disable swap (required by the kubelet)
# =============================================================================
# The kubelet refuses to start if swap is enabled because swap makes
# memory limits unreliable. See setup-controlplane.sh for detailed
# explanation of why.
stage "Disabling swap"

# Immediately turn off all swap
run "$SUDO swapoff -a"

# Comment out the swap line in /etc/fstab so it stays off after reboot
run "$SUDO sed -i '/\\sswap\\s/ s/^/#/' /etc/fstab"

# =============================================================================
# STAGE 3: Load kernel modules and configure network settings
# =============================================================================
# These are the SAME kernel requirements as the control plane.
# Every Kubernetes node (control plane OR worker) needs:
#   overlay      — for the container filesystem (image layers)
#   br_netfilter — for iptables to see bridged traffic (kube-proxy needs this)
stage "Loading kernel modules and network settings"

# Write module names to a persistent config file (survives reboots)
printf 'overlay\nbr_netfilter\n' | $SUDO tee /etc/modules-load.d/k8s.conf >/dev/null

# Load the modules into the running kernel right now
run "$SUDO modprobe overlay"
run "$SUDO modprobe br_netfilter"

# Configure sysctl network parameters:
#   bridge-nf-call-iptables  = bridged traffic goes through iptables
#   bridge-nf-call-ip6tables = same for IPv6
#   ip_forward               = allow packet forwarding between interfaces
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' | $SUDO tee /etc/sysctl.d/k8s.conf >/dev/null

# Apply all sysctl settings immediately
run "$SUDO sysctl --system >/dev/null"

# =============================================================================
# STAGE 4: Install and configure containerd (the container runtime)
# =============================================================================
# containerd is the program that actually runs containers. The kubelet
# tells containerd what containers to start/stop, and containerd manages
# their lifecycle using Linux kernel features (namespaces, cgroups).
stage "Installing and configuring containerd"

# Update the package list
run "$SUDO apt-get update -y -q"

# Install containerd
run "$SUDO apt-get install -y -q containerd"

# Create the config directory
run "$SUDO mkdir -p /etc/containerd"

# Generate the default configuration file
containerd config default | $SUDO tee /etc/containerd/config.toml >/dev/null

# Switch to the systemd cgroup driver.
# WHY? The kubelet uses systemd for cgroup management by default.
# containerd must use the same driver, otherwise they'll conflict.
# This sed command finds "SystemdCgroup = false" and changes it to "true".
run "$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"

# Restart containerd to apply the new configuration
run "$SUDO systemctl restart containerd"

# Enable containerd to start automatically on boot
run "$SUDO systemctl enable containerd >/dev/null 2>&1"

# =============================================================================
# STAGE 5: Install kubeadm, kubelet, and kubectl
# =============================================================================
# Even though workers don't run the API server, they still need:
#   kubelet — the node agent (runs and manages Pods)
#   kubeadm — used to join the cluster
#   kubectl — useful for debugging (optional but handy)
stage "Installing kubeadm, kubelet and kubectl ($K8S)"

# Install prerequisites for adding the Kubernetes apt repository
run "$SUDO apt-get install -y -q apt-transport-https ca-certificates curl gpg"

# Create the keyrings directory for GPG keys
run "$SUDO mkdir -p /etc/apt/keyrings"

# Download and install the Kubernetes repository's GPG signing key.
# This key verifies that packages come from the official Kubernetes project.
run "curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S/deb/Release.key | $SUDO gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"

# Add the Kubernetes apt repository to the system's package sources
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S/deb/ /" | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

# Refresh the package list to include packages from the new repo
run "$SUDO apt-get update -y -q"

# Install the three Kubernetes packages
run "$SUDO apt-get install -y -q kubelet kubeadm kubectl"

# Hold (pin) the packages to prevent accidental upgrades.
# Kubernetes upgrades must be done carefully using the official
# procedure — never by a random "apt upgrade".
run "$SUDO apt-mark hold kubelet kubeadm kubectl"

# =============================================================================
# STAGE 6: Join the cluster as a worker
# =============================================================================
# To join the cluster, we need the "join command" that was generated
# by the first control plane during "kubeadm init".
#
# The join command looks like:
#   sudo kubeadm join k8s-vip:6443 --token abc123.xyz \
#     --discovery-token-ca-cert-hash sha256:...
#
# It contains:
#   - The API server address (k8s-vip:6443)
#   - A bootstrap token (abc123.xyz) — proves this node was invited
#   - A CA cert hash (sha256:...) — proves the API server is genuine
#     (prevents man-in-the-middle attacks)
stage "Joining the cluster"

# Try to auto-load the join command from the Vagrant shared folder.
# The first control plane's setup script saves join commands to
# /vagrant/join-commands.txt (if running in Vagrant).
DEF=""
if [ -f /vagrant/join-commands.txt ]; then
  # Source the file to load WORKER_JOIN and CP_JOIN variables
  . /vagrant/join-commands.txt 2>/dev/null || true
  DEF="${WORKER_JOIN:-}"   # Use WORKER_JOIN as the default
fi

# Tell the user what to paste
info "Paste the WORKER join command from the first control plane"
info "(the shorter one, WITHOUT --control-plane). On a control plane you can"
info "regenerate it with:  kubeadm token create --print-join-command"

# Ask for the join command (auto-filled if Vagrant found one)
JOIN=$(ask "Worker join command" "$DEF")

# Validate that a command was provided
[ -n "$JOIN" ] || die "No join command provided."

# Safety check: make sure this isn't a control-plane join command.
# Workers should NOT use the --control-plane flag, which would make
# them run etcd, API server, etc. (that's not what we want here).
case "$JOIN" in
  *--control-plane*) die "That is a CONTROL-PLANE join — use the shorter worker command instead." ;;
esac

# Execute the join command. This:
#   1. Contacts the API server at the specified address
#   2. Validates the bootstrap token
#   3. Downloads the cluster CA certificate
#   4. Configures the kubelet with credentials
#   5. Starts the kubelet, which registers this node with the cluster
run "$JOIN"

# =============================================================================
# DONE — success message
# =============================================================================
echo   # Blank line
ok "${BLD}Worker joined.${RST}  Verify on a control plane with:  kubectl get nodes -o wide"
