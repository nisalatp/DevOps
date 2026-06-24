#!/usr/bin/env bash
# =============================================================================
# setup-controlplane.sh — Interactive, Narrated Control-Plane Setup
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Prepares a Linux machine to become a Kubernetes CONTROL-PLANE node.
#   It can either:
#     A) INITIALISE a brand-new cluster (the FIRST control plane), or
#     B) JOIN an existing cluster as an ADDITIONAL control plane.
#
#   The setup installs:
#     1. containerd     — the container runtime (runs containers)
#     2. kubeadm        — the cluster bootstrapper (sets up Kubernetes)
#     3. kubelet        — the node agent (manages Pods on this machine)
#     4. kubectl        — the CLI tool (you use it to interact with the cluster)
#     5. Calico CNI     — the network plugin (lets Pods talk to each other)
#
# WHAT IS A CONTROL PLANE?
#   The control plane is the "brain" of Kubernetes. It runs:
#     - kube-apiserver      → the REST API that all components talk to
#     - etcd                → the key-value database storing all cluster state
#     - kube-scheduler      → decides which node runs each new Pod
#     - kube-controller-mgr → ensures the desired state matches reality
#   For HA (High Availability), you run 3+ control planes so the cluster
#   survives even if one machine dies.
#
# HOW TO RUN:
#   Option A (Vagrant): vagrant ssh k8s-cp1, then run this script.
#   Option B (curl):    curl -fsSL http://<host-ip>:8000/setup-controlplane.sh | bash
#   (Prompts are read from /dev/tty so piping from curl still works.)
#
# WHAT YOU'LL LEARN:
#   - Why swap must be disabled for Kubernetes
#   - How Linux kernel modules enable container networking
#   - What containerd does and why SystemdCgroup matters
#   - How kubeadm bootstraps a Kubernetes cluster
#   - What the Calico CNI plugin does for Pod networking
#   - How join tokens and certificate keys enable cluster expansion
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

# ---- Helper functions (same as the other setup scripts) ----

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

# confirm() — asks a yes/no question. Returns 0 for yes, 1 for no.
confirm(){
  local a
  a=$(ask "$1 (y/n)" "${2:-y}")       # Default is "y" (yes)
  case "$a" in
    y|Y|yes|YES) return 0 ;;          # Yes → return success
    *) return 1 ;;                     # No → return failure
  esac
}

# ---- Detect if we need sudo ----
# id -u returns the current user's numeric ID. Root is always 0.
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# =============================================================================
# TITLE BANNER
# =============================================================================
printf '%s\n' "${BLU}${BLD}Kubernetes — Control-Plane Setup${RST}"
echo "This will prepare this machine and either start a new cluster or add this"
echo "node to an existing control plane. It explains each stage as it goes."
echo   # Blank line for spacing

# =============================================================================
# STAGE 0: Gather settings from the user
# =============================================================================
#
# SMART DEFAULTS: If this VM was created by Vagrant, /vagrant/cluster.yaml
# contains ALL the settings from configure.sh. We read that file and
# auto-detect this node's identity from its hostname (e.g., "k8s-cp1").
# The student can just press Enter through every prompt!
stage "Gathering settings"

# --- Auto-detect this node's "real" cluster IP ---
# hostname -I returns all IPs, separated by spaces.
# We filter out:
#   10.0.2.x  = VirtualBox NAT adapter (used for internet access, not cluster)
#   127.x     = localhost loopback
#   169.254.x = link-local (DHCP failure fallback)
# The first remaining IP is our best guess for the cluster-facing address.
NODE_IP_DEFAULT=$(hostname -I | tr ' ' '\n' | grep -vE '^(10\.0\.2\.|127\.|169\.254\.)' | head -1 || true)

# --- Try to auto-detect EVERYTHING from cluster.yaml ---
# /vagrant is a shared folder that Vagrant mounts on every VM.
# It contains the same files as the HA_AutoSetup directory on the host.
DEF_ENDPOINT=""   # Will hold the default API endpoint (VIP:6443)
DEF_NODE_IP=""    # Will hold this node's IP from cluster.yaml
DEF_K8S=""        # Will hold the Kubernetes version
DEF_POD_CIDR=""   # Will hold the Pod CIDR
DEF_CALICO=""     # Will hold the Calico version
DEF_FIRST="y"     # Will be "y" for first CP, "n" for additional CPs

if [ -f /vagrant/cluster.yaml ]; then
  info "Found /vagrant/cluster.yaml — auto-detecting settings from configure.sh..."

  # Extract the VIP from cluster.yaml and build the endpoint (VIP:6443).
  # The endpoint is the address ALL nodes use to reach the Kubernetes API.
  DEF_VIP=$(grep -E '^vip:' /vagrant/cluster.yaml | grep -oE '([0-9]+\.){3}[0-9]+' | head -1 || true)
  [ -n "$DEF_VIP" ] && DEF_ENDPOINT="k8s-vip:6443"

  # Extract Kubernetes version, Pod CIDR, and Calico version.
  # These use the same grep pattern: find the YAML key, extract the value.
  # sed removes surrounding quotes and everything before the value.
  DEF_K8S=$(grep -E '^k8s_version:' /vagrant/cluster.yaml | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' || true)
  DEF_POD_CIDR=$(grep -E '^pod_cidr:' /vagrant/cluster.yaml | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' || true)
  DEF_CALICO=$(grep -E '^calico_version:' /vagrant/cluster.yaml | sed 's/.*: *"\{0,1\}\([^"]*\)"\{0,1\}/\1/' || true)

  # --- Auto-detect this node's IP from its hostname ---
  # The Vagrantfile sets each VM's hostname to the name from cluster.yaml
  # (e.g., "k8s-cp1"). We search cluster.yaml for a line containing our
  # hostname and extract the IP from it.
  #
  # Example: if hostname is "k8s-cp1" and cluster.yaml has:
  #   - { name: k8s-cp1, ip: 192.168.56.11 }
  # then DEF_NODE_IP becomes "192.168.56.11".
  MY_HOSTNAME=$(hostname)
  DEF_NODE_IP=$(grep "$MY_HOSTNAME" /vagrant/cluster.yaml | grep -oE '([0-9]+\.){3}[0-9]+' | head -1 || true)

  # --- Auto-detect if this is the FIRST control plane ---
  # The first control plane in the list runs "kubeadm init" (creates the cluster).
  # All others run "kubeadm join" (join the existing cluster).
  # We compare our hostname with the FIRST k8s-cp entry in cluster.yaml.
  FIRST_CP=$(grep 'k8s-cp' /vagrant/cluster.yaml | head -1 | grep -oE 'k8s-cp[0-9]+' || true)
  if [ "$MY_HOSTNAME" = "$FIRST_CP" ]; then
    DEF_FIRST="y"    # This IS the first control plane → will run kubeadm init
  else
    DEF_FIRST="n"    # This is an additional CP → will run kubeadm join
  fi

  ok "Auto-detected: node=$MY_HOSTNAME, IP=${DEF_NODE_IP:-$NODE_IP_DEFAULT}, K8s=${DEF_K8S}, first=${DEF_FIRST}"
else
  info "No /vagrant/cluster.yaml found — you'll need to enter settings manually."
fi

# --- Ask for the control-plane endpoint ---
# This is the address ALL nodes use to reach the Kubernetes API.
# In our HA setup, this is the VIP managed by the load balancers.
# Format: hostname:port  (e.g., k8s-vip:6443)
# k8s-vip resolves because we added it to /etc/hosts via the Vagrantfile.
ENDPOINT=$(ask "Control-plane endpoint (the load-balancer VIP, host:port)" "${DEF_ENDPOINT:-k8s-vip:6443}")

# --- Ask for this node's advertise address ---
# This is the IP that this control plane tells other nodes to use when
# communicating with its API server. Must be reachable from all nodes.
# AUTO-DETECT: matched from hostname in cluster.yaml, or filtered from hostname -I.
NODE_IP=$(ask "This node's cluster IP (advertised to the cluster)" "${DEF_NODE_IP:-$NODE_IP_DEFAULT}")

# --- Kubernetes and network settings ---
# All auto-filled from cluster.yaml if present.
K8S=$(ask "Kubernetes version (minor)" "${DEF_K8S:-v1.36}")

# Pod CIDR — the IP range assigned to Pods (containers).
# Must NOT overlap with the VM subnet or your home network.
# Calico will manage this range and assign Pod IPs from it.
POD_CIDR=$(ask "Pod network CIDR (must not overlap your subnet)" "${DEF_POD_CIDR:-10.244.0.0/16}")

# Calico version — the CNI plugin version to install.
CALICO=$(ask "Calico version" "${DEF_CALICO:-v3.29.1}")

# --- Validate that we have a node IP ---
[ -n "$NODE_IP" ] || die "Could not determine this node's IP — re-run and enter it."

# --- Is this the first control plane, or joining an existing cluster? ---
# The FIRST control plane runs "kubeadm init" to create the cluster.
# Additional control planes run "kubeadm join" to join it.
# AUTO-DETECT: if hostname matches the first CP in cluster.yaml, default "yes".
if confirm "Is this the FIRST control plane (initialise a brand-new cluster)?" "$DEF_FIRST"; then
  FIRST=yes
else
  FIRST=no
fi

# --- Extract the VIP hostname and resolve its IP for certificate SANs ---
# The ENDPOINT looks like "k8s-vip:6443". We need the hostname part
# ("k8s-vip") and its resolved IP ("192.168.56.10") so we can tell kubeadm
# to include them as Subject Alternative Names (SANs) in the API server's
# TLS certificate.
#
# WHY IS THIS NEEDED?
#   When a client connects to https://k8s-vip:6443, TLS checks that the
#   server certificate is valid for "k8s-vip" (or its IP). If the cert
#   only contains the node's own IP (e.g., 192.168.56.11), the TLS
#   handshake fails with: "certificate is valid for 192.168.56.11, not ..."
#   By adding the VIP hostname AND its IP as extra SANs, the cert is
#   accepted regardless of whether the client connects via hostname or IP.
#
# ADDITIONAL PROBLEM: Vagrant VMs have a NAT interface (10.0.2.x) that
#   kubeadm can accidentally pick up. If kubeadm uses 10.0.2.15 as an
#   address but the cert doesn't include it, TLS fails. The fix is
#   twofold: (a) add extra SANs, and (b) pin the kubelet to NODE_IP.

# Extract just the hostname from the endpoint (strip the :port part).
# "cut -d: -f1" splits on ":" and takes the first field.
# Example: "k8s-vip:6443" → "k8s-vip"
VIP_HOST=$(echo "$ENDPOINT" | cut -d: -f1)

# Try to resolve the VIP hostname to its IP address.
# "getent hosts" queries /etc/hosts and DNS for the given hostname.
# "awk '{print $1}'" extracts just the IP from the output.
# If resolution fails, VIP_IP will be empty (and we skip it in the SANs).
VIP_IP=$(getent hosts "$VIP_HOST" 2>/dev/null | awk '{print $1}' | head -1 || true)

# Build the comma-separated list of extra SANs to add to the certificate.
# We always include the VIP hostname; we also include its IP if we resolved it.
# Example result: "k8s-vip,192.168.56.10"
EXTRA_SANS="$VIP_HOST"
if [ -n "$VIP_IP" ] && [ "$VIP_IP" != "$VIP_HOST" ]; then
  EXTRA_SANS="$EXTRA_SANS,$VIP_IP"
fi

# Show a summary of the gathered settings
info "Endpoint=${ENDPOINT}  Node IP=${NODE_IP}  K8s=${K8S}  First=${FIRST}"
info "Extra SANs for API cert: ${EXTRA_SANS}"

# =============================================================================
# STAGE 1: Disable swap (required by the kubelet)
# =============================================================================
# WHY DISABLE SWAP?
#   The kubelet (Kubernetes node agent) needs to accurately track memory
#   usage for each container. If swap is enabled, a container could use
#   disk-based "virtual memory" (swap), which is ~100x slower than RAM.
#   This makes resource limits unreliable and causes unpredictable
#   performance. Kubernetes therefore refuses to start if swap is on.
stage "Disabling swap (required by the kubelet)"

# "swapoff -a" immediately disables ALL swap partitions/files.
run "$SUDO swapoff -a"

# Comment out (disable) the swap entry in /etc/fstab so swap stays off
# after a reboot. The sed command finds lines containing "swap" surrounded
# by whitespace and prepends a # to comment them out.
#   sed -i  = edit the file in-place
#   '/\sswap\s/ s/^/#/'  = find lines matching the pattern, add # at start
run "$SUDO sed -i '/\\sswap\\s/ s/^/#/' /etc/fstab"

ok "Swap is off."

# =============================================================================
# STAGE 2: Load kernel modules and configure network settings
# =============================================================================
# Container networking requires two Linux kernel features:
#   1. "overlay"      — the overlay filesystem, used by containerd to layer
#                        container images efficiently (copy-on-write layers).
#   2. "br_netfilter" — allows iptables to see traffic crossing Linux bridges.
#                        Without this, Kubernetes network policies won't work.
stage "Loading kernel modules and network settings"

# Write the required module names to a config file so they load on every boot.
# /etc/modules-load.d/ is a directory where each .conf file lists kernel
# modules to load at startup.
info "Writing /etc/modules-load.d/k8s.conf (overlay, br_netfilter)"
printf 'overlay\nbr_netfilter\n' | $SUDO tee /etc/modules-load.d/k8s.conf >/dev/null

# Load the modules immediately (without waiting for a reboot).
# "modprobe" loads a kernel module into the running kernel.
run "$SUDO modprobe overlay"
run "$SUDO modprobe br_netfilter"

# Configure kernel network parameters required by Kubernetes.
# These are "sysctl" settings — runtime kernel tuning parameters.
#
# net.bridge.bridge-nf-call-iptables  = 1
#   → Makes bridged IPv4 traffic pass through iptables rules.
#     Without this, Kubernetes Services (kube-proxy) can't work because
#     traffic between containers on the same node would bypass iptables.
#
# net.bridge.bridge-nf-call-ip6tables = 1
#   → Same as above, but for IPv6 traffic.
#
# net.ipv4.ip_forward = 1
#   → Allows this machine to forward packets between network interfaces.
#     Required for routing traffic between Pods on different nodes.
#     Without this, the node acts as a dead-end for network traffic.
info "Writing /etc/sysctl.d/k8s.conf (ip_forward, bridge-nf-call-iptables)"
printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' | $SUDO tee /etc/sysctl.d/k8s.conf >/dev/null

# Apply ALL sysctl settings from all config files.
# "sysctl --system" reads /etc/sysctl.conf and /etc/sysctl.d/*.conf
run "$SUDO sysctl --system >/dev/null"

ok "Kernel ready for container networking."

# =============================================================================
# STAGE 3: Install and configure containerd (the container runtime)
# =============================================================================
# WHAT IS containerd?
#   containerd is the software that actually runs containers. Kubernetes
#   tells containerd "run this container image on this node", and containerd
#   handles pulling the image, creating the container, managing its lifecycle,
#   and cleaning up when it exits.
#
#   containerd is the standard runtime used by Docker and Kubernetes.
#   Docker is actually just a wrapper around containerd! Kubernetes talks
#   to containerd directly, cutting out the Docker middleman.
stage "Installing and configuring containerd"

# Update the package list from the OS repositories
run "$SUDO apt-get update -y -q"

# Install containerd from the OS package repositories
run "$SUDO apt-get install -y -q containerd"

# Create the containerd configuration directory
run "$SUDO mkdir -p /etc/containerd"

# Generate the default containerd configuration file.
# "containerd config default" outputs a complete config.toml with all
# the default settings. We save this as a starting point and then
# modify the one setting we need to change.
info "Generating default config and enabling the systemd cgroup driver"
containerd config default | $SUDO tee /etc/containerd/config.toml >/dev/null

# Enable the SystemdCgroup driver in containerd's configuration.
#
# WHY? Linux uses "cgroups" (control groups) to limit and track resource
# usage (CPU, memory) per process. There are two cgroup drivers:
#   - cgroupfs  = containerd manages cgroups directly
#   - systemd   = systemd manages cgroups (since systemd already does this!)
#
# If the kubelet uses the systemd driver (which it does by default) but
# containerd uses cgroupfs, they'll fight over cgroup management and
# the node will become unstable. So we set both to use systemd.
run "$SUDO sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml"

# Restart containerd to pick up the new configuration
run "$SUDO systemctl restart containerd"

# Enable containerd to start automatically on boot
# ">/dev/null 2>&1" suppresses all output (both stdout and stderr)
run "$SUDO systemctl enable containerd >/dev/null 2>&1"

ok "containerd is running with SystemdCgroup=true."

# =============================================================================
# STAGE 4: Install kubeadm, kubelet, and kubectl
# =============================================================================
# These are the three essential Kubernetes binaries:
#
#   kubeadm  — the cluster bootstrapper. Handles:
#              • "kubeadm init" = create a new cluster
#              • "kubeadm join" = add a node to an existing cluster
#              • Certificate generation, etcd setup, etc.
#
#   kubelet  — the node agent that runs on every node. It:
#              • Watches the API server for Pods assigned to this node
#              • Tells containerd to start/stop containers
#              • Reports node health back to the API server
#
#   kubectl  — the command-line tool for interacting with Kubernetes:
#              • kubectl get pods, kubectl apply -f, kubectl logs, etc.
#              • Talks to the API server via HTTPS
stage "Installing kubeadm, kubelet and kubectl ($K8S)"

# Install prerequisite packages needed to add the Kubernetes apt repository.
#   apt-transport-https = allows apt to fetch packages over HTTPS
#   ca-certificates     = trusted certificate authorities for HTTPS
#   curl                = command-line HTTP client
#   gpg                 = GNU Privacy Guard for verifying package signatures
run "$SUDO apt-get install -y -q apt-transport-https ca-certificates curl gpg"

# Create the directory where apt stores GPG keyrings for third-party repos
run "$SUDO mkdir -p /etc/apt/keyrings"

# Download the Kubernetes apt repository's GPG signing key.
# This key proves that packages from pkgs.k8s.io are genuine.
#   curl -fsSL = fetch silently, fail on error
#   gpg --dearmor = convert the ASCII-armored key to binary format
#   -o = save to the keyrings directory
run "curl -fsSL https://pkgs.k8s.io/core:/stable:/$K8S/deb/Release.key | $SUDO gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg"

# Add the Kubernetes apt repository to the system's package sources.
# "signed-by" tells apt which GPG key to use to verify packages from this repo.
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$K8S/deb/ /" | $SUDO tee /etc/apt/sources.list.d/kubernetes.list >/dev/null

# Refresh package list to include the newly added Kubernetes repo
run "$SUDO apt-get update -y -q"

# Install the three Kubernetes packages
run "$SUDO apt-get install -y -q kubelet kubeadm kubectl"

# "Hold" the packages — prevent them from being automatically upgraded.
# Kubernetes is very version-sensitive. Accidentally upgrading kubeadm
# without upgrading the cluster properly can break everything.
# You should only upgrade these packages intentionally using the official
# Kubernetes upgrade procedure.
run "$SUDO apt-mark hold kubelet kubeadm kubectl"

ok "Kubernetes tools installed and held."

# =============================================================================
# PRE-FLIGHT: Pin the kubelet to the correct node IP
# =============================================================================
# Vagrant VMs have TWO network interfaces:
#   1. eth0 / enp0s3  — NAT adapter (10.0.2.x) used for internet access
#   2. eth1 / enp0s8  — host-only adapter (192.168.56.x) used for cluster comms
#
# By default, the kubelet might auto-detect the NAT IP (10.0.2.15) and
# advertise it to the cluster. This causes problems:
#   - Other nodes can't reach this node via 10.0.2.15 (NAT is host-only)
#   - TLS certificates don't include 10.0.2.15 → cert verification fails
#
# FIX: Create a kubelet configuration drop-in that explicitly sets the
# node IP to the cluster-facing address (192.168.56.x).
#
# A "drop-in" is a small config file in /etc/systemd/system/<service>.d/
# that overrides or extends the service's default settings without
# modifying the main unit file.
stage "Pinning kubelet to node IP $NODE_IP"
info "Creating a systemd drop-in so the kubelet always uses $NODE_IP (not the NAT interface)."
run "$SUDO mkdir -p /etc/systemd/system/kubelet.service.d"

# Write a drop-in that passes --node-ip to the kubelet.
# [Service] Environment= sets an environment variable that the kubelet
# startup script reads. KUBELET_EXTRA_ARGS is the standard variable
# for passing additional flags to the kubelet.
printf '[Service]\nEnvironment="KUBELET_EXTRA_ARGS=--node-ip=%s"\n' "$NODE_IP" \
  | $SUDO tee /etc/systemd/system/kubelet.service.d/20-node-ip.conf >/dev/null

# Reload systemd so it picks up the new drop-in file.
# "daemon-reload" re-reads all unit files and drop-ins.
run "$SUDO systemctl daemon-reload"
ok "Kubelet will use $NODE_IP as its node address."

# =============================================================================
# BRANCH: Is this the FIRST control plane, or an ADDITIONAL one?
# =============================================================================
if [ "$FIRST" = "yes" ]; then

  # =========================================================================
  # STAGE 7: Initialise the cluster with kubeadm init (FIRST control plane)
  # =========================================================================
  # "kubeadm init" creates a brand-new Kubernetes cluster on this machine.
  # It generates all the certificates, starts etcd, the API server,
  # scheduler, and controller-manager, and produces join tokens for
  # other nodes to join.
  #
  # Key flags:
  #   --control-plane-endpoint = the address ALL nodes use to reach the API.
  #     We set this to the load-balancer VIP so traffic is always balanced.
  #     This is CRITICAL for HA — without it, nodes would talk directly
  #     to this specific control plane and bypass the load balancer.
  #
  #   --upload-certs = uploads the control-plane certificates to a Secret
  #     in the cluster, so other control planes can download them when
  #     joining (otherwise you'd have to manually copy cert files).
  #
  #   --pod-network-cidr = the IP range for Pods. Calico uses this to
  #     assign IPs to containers. Must not overlap with node IPs.
  #
  #   --apiserver-advertise-address = the IP this API server tells other
  #     components to use. Must be the node's cluster-facing IP (not NAT).
  #
  #   --apiserver-cert-extra-sans = additional hostnames/IPs to include in
  #     the API server's TLS certificate. We add the VIP hostname and IP
  #     so clients connecting via the load balancer pass TLS verification.
  #     Without this, the cert only contains this node's IP and the
  #     Kubernetes service IP — connections via the VIP would fail with:
  #     "certificate is valid for 192.168.56.11, not 192.168.56.10"
  stage "Initialising the control plane (kubeadm init)"
  info "Using --control-plane-endpoint=$ENDPOINT so every node reaches the API via the load balancer."
  info "Adding --apiserver-cert-extra-sans=$EXTRA_SANS so the TLS cert covers the VIP."
  run "$SUDO kubeadm init --control-plane-endpoint '$ENDPOINT' --upload-certs --pod-network-cidr='$POD_CIDR' --apiserver-advertise-address='$NODE_IP' --apiserver-cert-extra-sans='$EXTRA_SANS'"

  # =========================================================================
  # STAGE 7: Fix kubeconfig server endpoints
  # =========================================================================
  # BUG IN VAGRANT ENVIRONMENTS:
  #   kubeadm init just completed and generated kubeconfig files at:
  #     /etc/kubernetes/admin.conf
  #     /etc/kubernetes/kubelet.conf
  #     /etc/kubernetes/controller-manager.conf
  #     /etc/kubernetes/scheduler.conf
  #
  #   Despite passing --apiserver-advertise-address='192.168.56.11', kubeadm
  #   may write these kubeconfig files with:
  #     server: https://10.0.2.15:6443    <-- NAT interface (WRONG!)
  #   instead of:
  #     server: https://k8s-vip:6443      <-- VIP endpoint (CORRECT)
  #
  # WHY THIS IS A PROBLEM:
  #   Later stages (kubectl, upload-certs) read these kubeconfig files
  #   to contact the API server. When they connect to 10.0.2.15:6443,
  #   TLS verification fails because the API server certificate only
  #   has SANs for 192.168.56.11, 192.168.56.10, and 10.96.0.1 —
  #   NOT 10.0.2.15.
  #
  #   Error: "certificate is valid for 10.96.0.1, 192.168.56.11,
  #            192.168.56.10, not 10.0.2.15"
  #
  # FIX: Use sed to replace the server URL in ALL kubeconfig files
  #      with the correct VIP-based endpoint.
  stage "Fixing kubeconfig server endpoints"

  # Build the correct server URL from the ENDPOINT variable.
  # ENDPOINT is e.g. "k8s-vip:6443" → server becomes "https://k8s-vip:6443"
  KUBECONFIG_ENDPOINT=$(echo "$ENDPOINT" | cut -d: -f1)
  KUBECONFIG_SERVER="https://${KUBECONFIG_ENDPOINT}:6443"

  info "Patching kubeconfig files to use $KUBECONFIG_SERVER (instead of NAT IP)."

  # Loop through all kubeconfig files that kubeadm generates.
  # For each file:
  #   1. Check if it exists (-f test)
  #   2. Use sed to replace any "server: https://..." line with the correct URL
  #      sed -i = edit the file in-place
  #      's|...|...|g' = substitute (using | as delimiter instead of / to avoid
  #      escaping the slashes in URLs)
  #
  # NOTE: In Kubernetes 1.29+, kubeadm also creates "super-admin.conf".
  # This file is used for privileged operations like "upload-certs".
  # If we don't patch it, upload-certs will still connect to 10.0.2.15
  # and fail with a TLS certificate error.
  for cfg in /etc/kubernetes/admin.conf \
             /etc/kubernetes/super-admin.conf \
             /etc/kubernetes/kubelet.conf \
             /etc/kubernetes/controller-manager.conf \
             /etc/kubernetes/scheduler.conf; do
    if [ -f "$cfg" ]; then
      $SUDO sed -i "s|server:.*|server: $KUBECONFIG_SERVER|g" "$cfg"
    fi
  done

  ok "Kubeconfig files patched to use $KUBECONFIG_SERVER."

  # =========================================================================
  # STAGE 8: Configure kubectl for the current user
  # =========================================================================
  # kubeadm init creates a kubeconfig file at /etc/kubernetes/admin.conf
  # with credentials (certificates) to talk to the API server as admin.
  # We copy it to ~/.kube/config so kubectl can find it automatically.
  # NOTE: We patched admin.conf in the previous stage, so the copy
  # will have the correct server endpoint.
  stage "Configuring kubectl for $(whoami)"

  # Create the ~/.kube directory if it doesn't exist
  run "mkdir -p \$HOME/.kube"

  # Copy the admin kubeconfig to the user's home directory
  # -f = force (overwrite if it already exists)
  run "$SUDO cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config"

  # Change ownership so the current user (not root) owns the config file.
  # $(id -u) = current user's numeric ID
  # $(id -g) = current user's numeric group ID
  run "$SUDO chown \$(id -u):\$(id -g) \$HOME/.kube/config"

  ok "kubectl is ready (try: kubectl get nodes)."

  # =========================================================================
  # STAGE 9: Install the Calico CNI (Container Network Interface) plugin
  # =========================================================================
  # WHAT IS A CNI PLUGIN?
  #   Kubernetes doesn't handle Pod networking itself. It delegates to a
  #   "CNI plugin" — a separate program that:
  #     1. Assigns IP addresses to Pods
  #     2. Sets up network routes so Pods on different nodes can reach
  #        each other
  #     3. Implements Network Policies (firewall rules between Pods)
  #
  #   Calico uses VXLAN encapsulation: it wraps Pod traffic in UDP packets
  #   and tunnels them between nodes. This works even on networks that
  #   don't support BGP routing (like VirtualBox host-only networks).
  stage "Installing the Calico pod network ($CALICO)"

  # Install the Tigera operator, which manages Calico's lifecycle.
  # An "operator" is a Kubernetes pattern where a controller watches
  # for custom resources (like Installation) and reconciles them.
  run "kubectl create -f https://raw.githubusercontent.com/projectcalico/calico/$CALICO/manifests/tigera-operator.yaml"

  # Create the Calico Installation custom resource.
  # This tells the Tigera operator how to configure Calico.
  # "cat <<EOF | kubectl create -f -" passes the YAML to kubectl via stdin.
  # The "-f -" flag tells kubectl to read from stdin instead of a file.
  info "Creating an IP pool that matches $POD_CIDR (VXLAN encapsulation)"
  cat <<EOF | kubectl create -f -
# This is a Kubernetes custom resource (CR) — a YAML object that the
# Tigera operator watches for and acts upon.
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

  # =========================================================================
  # STAGE 11: Wait for the API server to stabilise
  # =========================================================================
  # After installing Calico, the API server is busy processing many new
  # resources (CustomResourceDefinitions, Deployments, DaemonSets, etc.).
  # If we immediately run upload-certs, it can fail with:
  #   "client rate limiter Wait returned an error: rate: Wait(n=1) would
  #    exceed context deadline"
  # This means the API server is overloaded and timing out requests.
  #
  # FIX: Wait until the API server is responsive before proceeding.
  # We use "kubectl cluster-info" as a lightweight health check.
  stage "Waiting for the API server to stabilise"
  info "The API server needs a moment to process the Calico resources..."

  # Retry loop: try up to 12 times (12 × 10s = 2 minutes max wait).
  # Each iteration runs "kubectl cluster-info" which contacts the API server.
  # If it succeeds, the API is ready and we break out of the loop.
  # If it fails, we wait 10 seconds and try again.
  RETRIES=12
  for i in $(seq 1 $RETRIES); do
    if kubectl cluster-info &>/dev/null; then
      ok "API server is responsive."
      break
    fi
    info "Attempt $i/$RETRIES — API server not ready yet, waiting 10s..."
    sleep 10
  done

  # Extra grace period: even after cluster-info succeeds, give the API
  # server a few more seconds to finish processing background resources.
  # This prevents the rate limiter from kicking in during upload-certs.
  info "Giving the API server 15s grace period to finish background work..."
  sleep 15

  # =========================================================================
  # STAGE 12: Generate join commands for the other nodes
  # =========================================================================
  # Other nodes need two pieces of information to join the cluster:
  #   1. A bootstrap token  — a short-lived secret that proves the new
  #      node was invited (prevents random machines from joining).
  #   2. A certificate key  — (control planes only) the encryption key
  #      to download the shared control-plane certificates.
  stage "Generating the join commands for the other nodes"

  # Generate a new bootstrap token and print the complete join command.
  # "kubeadm token create --print-join-command" outputs something like:
  #   kubeadm join k8s-vip:6443 --token abc123.xyz --discovery-token-ca-cert-hash sha256:...
  WJOIN="sudo $(kubeadm token create --print-join-command)"

  # Upload certificates and get the certificate key.
  # "kubeadm init phase upload-certs --upload-certs" re-uploads the
  # control-plane certificates and prints a new decryption key.
  # The key is on the last line of the output.
  CKEY=$($SUDO kubeadm init phase upload-certs --upload-certs | tail -n1)

  # Build the control-plane join command by adding --control-plane and
  # the certificate key to the worker join command.
  CPJOIN="$WJOIN --control-plane --certificate-key $CKEY"

  echo   # Blank line

  # Display the control-plane join command
  info "${BLD}CONTROL-PLANE join (run on the other control planes):${RST}"
  echo "      $CPJOIN"
  echo

  # Display the worker join command (shorter — no --control-plane flag)
  info "${BLD}WORKER join (run on each worker):${RST}"
  echo "      $WJOIN"
  echo

  # If running in Vagrant, save the join commands to a shared file.
  # /vagrant is a shared folder that all Vagrant VMs can access.
  # This lets the other setup scripts (setup-worker.sh, etc.) read
  # the join commands automatically without manual copy-pasting.
  if [ -d /vagrant ]; then
    # printf %q escapes special characters so the commands can be safely
    # sourced (loaded) by another script using ". /vagrant/join-commands.txt"
    printf 'WORKER_JOIN=%q\nCP_JOIN=%q\n' "$WJOIN" "$CPJOIN" | $SUDO tee /vagrant/join-commands.txt >/dev/null
    ok "Saved both commands to /vagrant/join-commands.txt — the other scripts read it automatically."
  else
    warn "Copy the two commands above; you'll paste them on the other nodes."
  fi

else

  # =========================================================================
  # STAGE 5 (alt): Join as an ADDITIONAL control plane
  # =========================================================================
  # This node is NOT the first control plane — it's joining an existing
  # cluster. We need the join command that was generated by the first
  # control plane during kubeadm init.
  stage "Joining this node as an ADDITIONAL control plane"

  # Try to auto-load the join command from the shared Vagrant folder
  DEF=""
  if [ -f /vagrant/join-commands.txt ]; then
    # Source (load) the file, which sets WORKER_JOIN and CP_JOIN variables.
    # "2>/dev/null || true" silently ignores any errors.
    . /vagrant/join-commands.txt 2>/dev/null || true
    DEF="${CP_JOIN:-}"   # Use CP_JOIN as the default if it was set
  fi

  # Ask the user for the join command (auto-filled if Vagrant found one)
  info "Paste the CONTROL-PLANE join command from the first control plane"
  info "(the long one ending in --control-plane --certificate-key)."
  JOIN=$(ask "Control-plane join command" "$DEF")

  # Validate that a command was provided
  [ -n "$JOIN" ] || die "No join command provided."

  # Warn if the command doesn't look like a control-plane join
  # (it should contain "--control-plane")
  case "$JOIN" in
    *--control-plane*) : ;;   # Looks correct — do nothing (":" is a no-op)
    *) warn "That doesn't look like a control-plane join (missing --control-plane)." ;;
  esac

  # Execute the join command, adding --apiserver-advertise-address so
  # this control plane advertises the correct IP to the cluster.
  run "$JOIN $([ -n "$NODE_IP" ] && echo --apiserver-advertise-address=$NODE_IP)"

  # =========================================================================
  # Fix kubeconfig server endpoints (same issue as first CP — see Stage 7)
  # =========================================================================
  # After kubeadm join, the kubeconfig files on this node may also contain
  # the NAT IP (10.0.2.15) instead of the VIP. Patch them before using kubectl.
  stage "Fixing kubeconfig server endpoints"

  KUBECONFIG_ENDPOINT=$(echo "$ENDPOINT" | cut -d: -f1)
  KUBECONFIG_SERVER="https://${KUBECONFIG_ENDPOINT}:6443"

  info "Patching kubeconfig files to use $KUBECONFIG_SERVER (instead of NAT IP)."

  for cfg in /etc/kubernetes/admin.conf \
             /etc/kubernetes/super-admin.conf \
             /etc/kubernetes/kubelet.conf \
             /etc/kubernetes/controller-manager.conf \
             /etc/kubernetes/scheduler.conf; do
    if [ -f "$cfg" ]; then
      $SUDO sed -i "s|server:.*|server: $KUBECONFIG_SERVER|g" "$cfg"
    fi
  done

  ok "Kubeconfig files patched to use $KUBECONFIG_SERVER."

  # Configure kubectl for this node (same as Stage 6 above)
  stage "Configuring kubectl for $(whoami)"
  run "mkdir -p \$HOME/.kube"
  run "$SUDO cp -f /etc/kubernetes/admin.conf \$HOME/.kube/config"
  run "$SUDO chown \$(id -u):\$(id -g) \$HOME/.kube/config"
fi

# =============================================================================
# DONE — success message
# =============================================================================
echo   # Blank line
ok "${BLD}Control-plane node is set up.${RST}"
info "Check progress with:  kubectl get nodes   and   kubectl get pods -A"
