#!/usr/bin/env bash
# =============================================================================
# setup-loadbalancer.sh — Interactive, Narrated HAProxy + Keepalived Setup
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Sets up a LOAD BALANCER node for the Kubernetes HA cluster. It installs:
#     1. HAProxy    — a TCP/HTTP load balancer that distributes API requests
#                     across all control-plane nodes (round-robin).
#     2. Keepalived — (optional) manages a Virtual IP (VIP) that "floats"
#                     between multiple load balancers. If the active LB dies,
#                     Keepalived moves the VIP to a backup LB automatically.
#
# WHY DO WE NEED THIS?
#   In a Kubernetes HA (High Availability) cluster, there are multiple
#   control-plane nodes (each running its own API server on port 6443).
#   But kubectl and kubelets need a SINGLE address to talk to.
#   The load balancer provides that single address (the VIP) and forwards
#   traffic to whichever control planes are healthy.
#
# HOW TO RUN:
#   Option A (Vagrant): vagrant ssh k8s-lb1, then run this script.
#   Option B (curl):    curl -fsSL http://<host-ip>:8000/setup-loadbalancer.sh | bash
#
# WHAT YOU'LL LEARN:
#   - What a reverse proxy / load balancer does (HAProxy)
#   - What a Virtual IP (VIP) is and how VRRP failover works (Keepalived)
#   - TCP mode load balancing (Layer 4)
#   - How to use systemctl to manage Linux services
# =============================================================================

# ---- Shell safety settings ----
# -e  = exit immediately if ANY command fails (non-zero exit code)
# -u  = treat unset variables as errors (catches typos like $NAEM)
# -o pipefail = if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# ---- Define colour codes for pretty terminal output ----
# c() generates ANSI escape sequences for terminal colours.
# These make the output colourful and easier to read in the terminal.
c(){ printf '\033[%sm' "$1"; }
BLU=$(c '1;36')   # Bold Cyan    — used for stage headings
GRN=$(c '1;32')   # Bold Green   — used for success messages and commands
YLW=$(c '0;33')   # Yellow       — used for warnings
RED=$(c '1;31')   # Bold Red     — used for fatal errors
BLD=$(c '1')      # Bold (white) — used to emphasise important text
RST=$(c '0')      # Reset        — turns off all formatting

# ---- Stage counter ----
# We number each major step (Stage 1, Stage 2, ...) so students can
# follow the progress and understand the order of operations.
STAGE=0

# ---- Helper functions ----

# stage() — prints a coloured stage header like "== Stage 1: Installing ==".
# Each call increments STAGE by 1 automatically.
stage(){ STAGE=$((STAGE+1)); printf '\n%s== Stage %s: %s ==%s\n' "$BLU$BLD" "$STAGE" "$*" "$RST"; }

# info() — prints an indented informational message (3-space indent).
info(){ printf '   %s\n' "$*"; }

# run() — prints a command in green (like a terminal prompt), then executes it.
# This lets students see exactly which command is being run.
# eval "$@" interprets the string as a shell command.
run(){ printf '   %s$ %s%s\n' "$GRN" "$*" "$RST"; eval "$@"; }

# ok() — prints a green checkmark (✓) with a success message.
ok(){ printf '   %s\xe2\x9c\x93 %s%s\n' "$GRN" "$*" "$RST"; }

# warn() — prints a yellow exclamation mark (!) with a warning message.
warn(){ printf '   %s! %s%s\n' "$YLW" "$*" "$RST"; }

# die() — prints a red cross (✗) with an error message, then exits with
# status code 1 (failure). The >&2 sends the message to stderr.
die(){ printf '%s\xe2\x9c\x97 %s%s\n' "$RED" "$*" "$RST" >&2; exit 1; }

# ask() — prompts the user for input with an optional default value.
# See configure.sh for a detailed explanation of how this function works.
# Key detail: we read from /dev/tty so this works even when the script
# is piped from curl (curl ... | bash).
ask(){
  local p="$1" d="${2:-}" a           # p=prompt, d=default, a=answer
  if [ -n "$d" ]; then                # If a default was provided...
    printf '%s [%s]: ' "$p" "$d" >/dev/tty   # Show "Prompt [default]: "
  else
    printf '%s: ' "$p" >/dev/tty             # Show "Prompt: " (no default)
  fi
  IFS= read -r a </dev/tty || true   # Read the user's input from the terminal
  printf '%s' "${a:-$d}"              # Output the answer, or the default if blank
}

# confirm() — asks a yes/no question. Returns 0 (true) for yes, 1 (false) for no.
# Usage:  if confirm "Enable feature X?"; then ... fi
confirm(){
  local a
  a=$(ask "$1 (y/n)" "${2:-y}")       # Ask the question with default "y"
  case "$a" in
    y|Y|yes|YES) return 0 ;;          # User said yes → return success (0)
    *) return 1 ;;                     # Anything else → return failure (1)
  esac
}

# ---- Detect if we need sudo ----
# If the script is already running as root (user ID 0), we don't need sudo.
# Otherwise, we prefix privileged commands with sudo.
SUDO=""
[ "$(id -u)" -ne 0 ] && SUDO="sudo"

# =============================================================================
# TITLE BANNER — show what this script does
# =============================================================================
printf '%s\n' "${BLU}${BLD}Kubernetes — Load Balancer Setup (HAProxy + Keepalived)${RST}"
echo "Fronts the API servers of all control planes behind one virtual IP (VIP)."
echo   # Blank line for spacing

# =============================================================================
# STAGE 0: Gather settings from the user
# =============================================================================
# We need to know: VIP address, control-plane IPs, network interface, and
# whether to set up Keepalived for VIP failover.
stage "Gathering settings"

# --- Try to auto-detect defaults from cluster.yaml ---
# If this VM was created by Vagrant, /vagrant is a shared folder that
# contains the project files (including cluster.yaml). We try to
# extract sensible defaults from it so the user doesn't have to type
# everything manually.
DEF_VIP=""    # Will hold the default VIP address if found
DEF_CPS=""    # Will hold the default control-plane IPs if found

if [ -f /vagrant/cluster.yaml ]; then
  # Extract the VIP IP from the "vip:" line using grep.
  # The regex matches patterns like 192.168.56.10.
  DEF_VIP=$(grep -E '^vip:' /vagrant/cluster.yaml | grep -oE '([0-9]+\.){3}[0-9]+' | head -1 || true)

  # Extract all control-plane IPs (from lines containing "k8s-cp"),
  # then join them with commas using "paste -sd, -".
  DEF_CPS=$(grep 'k8s-cp' /vagrant/cluster.yaml | grep -oE '([0-9]+\.){3}[0-9]+' | paste -sd, -)
fi

# --- Ask the user for the VIP (Virtual IP) ---
# This is the single IP address that all nodes will use to reach the
# Kubernetes API. HAProxy listens on this IP, and Keepalived ensures
# it's always assigned to a healthy load balancer.
VIP=$(ask "Virtual IP (VIP) for the API" "${DEF_VIP:-192.168.56.10}")

# --- Ask for control-plane IPs ---
# These are the backend servers that HAProxy will forward traffic to.
# Each control plane runs kube-apiserver on port 6443.
CPS=$(ask "Control-plane IPs (comma-separated)" "${DEF_CPS:-}")
[ -n "$CPS" ] || die "Enter at least one control-plane IP."

# --- Detect this node's IP address ---
# "hostname -I" lists all IPs assigned to this machine.
# We filter out internal/virtual IPs that aren't the "real" cluster IP:
#   10.0.2.x  = VirtualBox NAT adapter (used for internet, not cluster comms)
#   127.x     = localhost (loopback)
#   169.254.x = link-local (self-assigned when DHCP fails)
NODE_IP=$(hostname -I | tr ' ' '\n' | grep -vE '^(10\.0\.2\.|127\.|169\.254\.)' | head -1 || true)

# --- Detect the network interface for the VIP ---
# "ip -o -4 addr show" lists all IPv4 addresses with their interface names.
# We find the interface that holds NODE_IP (e.g., "eth1") so Keepalived
# knows which interface to assign the VIP to.
IFACE=$(ip -o -4 addr show 2>/dev/null | awk -v ip="${NODE_IP:-x}" '$4 ~ "^"ip"/"{print $2; exit}')
IFACE=$(ask "Network interface that holds the VIP" "${IFACE:-eth1}")

# --- Ask whether to set up Keepalived VIP failover ---
# If you only have 1 load balancer, there's no failover (if it dies,
# the cluster is unreachable). With 2+ LBs, Keepalived moves the VIP
# to a backup LB automatically.
DO_VIP=no
if confirm "Set up the Keepalived VIP on this node? (yes if you have 2+ load balancers)"; then
  DO_VIP=yes
fi

# --- Keepalived-specific settings (only if DO_VIP=yes) ---
STATE=BACKUP    # Default VRRP state: BACKUP (standby)
PRIO=100        # Default priority: 100 (lower than MASTER)

if [ "$DO_VIP" = yes ]; then
  # One LB must be the MASTER (active), the rest are BACKUPs (standby).
  # The MASTER gets priority 101 (higher = preferred).
  if confirm "Is this the PRIMARY (MASTER) load balancer?"; then
    STATE=MASTER   # This node will be the active VIP holder
    PRIO=101       # Higher priority wins the election
  fi

  # VRID (Virtual Router ID) — must be the same on ALL load balancers
  # in this cluster. It identifies which VRRP group they belong to.
  # Range: 1-255. Different clusters on the same network need different VRIDs.
  VRID=$(ask "VRRP virtual_router_id (same on all LBs)" "51")

  # VRRP authentication password — shared secret between all LBs.
  # All LBs in the same VRRP group must use the same password.
  VPASS=$(ask "VRRP shared password (same on all LBs)" "k8svip42")
fi

# =============================================================================
# STAGE 1: Install HAProxy (and optionally Keepalived)
# =============================================================================
stage "Installing HAProxy${DO_VIP:+ and Keepalived}"

# Update the apt package index (list of available packages)
run "$SUDO apt-get update -y -q"

# Install packages based on whether we need Keepalived.
# -y = auto-answer "yes" to prompts
# -q = quiet mode (less verbose output)
# psmisc provides "killall" which Keepalived's health check uses.
if [ "$DO_VIP" = yes ]; then
  run "$SUDO apt-get install -y -q haproxy keepalived psmisc"
else
  run "$SUDO apt-get install -y -q haproxy"
fi

# =============================================================================
# STAGE 2: Configure HAProxy to balance the Kubernetes API servers
# =============================================================================
stage "Configuring HAProxy to balance the API servers"

# Check if HAProxy is already configured for Kubernetes (idempotency).
# "Idempotent" means running the script twice produces the same result
# as running it once — it won't duplicate the configuration.
if $SUDO grep -q 'kubernetes-api' /etc/haproxy/haproxy.cfg 2>/dev/null; then
  warn "An existing kubernetes-api block was found — leaving haproxy.cfg as-is."
else
  # Append the frontend and backend configuration to haproxy.cfg.
  #
  # HAProxy works in two parts:
  #   FRONTEND = the "listening" side (accepts incoming connections)
  #   BACKEND  = the "forwarding" side (sends traffic to real servers)
  #
  # "mode tcp" means Layer 4 (TCP) load balancing. HAProxy doesn't inspect
  # the HTTP/HTTPS content — it just forwards raw TCP connections.
  # This is necessary because the Kubernetes API uses TLS, and HAProxy
  # shouldn't (and can't) decrypt it.
  {
    echo ""                                           # Blank line separator

    # FRONTEND: listen on all interfaces (*) on port 6443 (Kubernetes API port)
    echo "frontend kubernetes-api"
    echo "    bind *:6443"                            # Listen on port 6443
    echo "    mode tcp"                               # Layer 4 (TCP) mode
    echo "    option tcplog"                          # Log TCP connection info
    echo "    default_backend kube-apiservers"        # Forward to this backend

    echo ""                                           # Blank line separator

    # BACKEND: the actual control-plane servers to forward traffic to
    echo "backend kube-apiservers"
    echo "    mode tcp"                               # Must match frontend mode
    echo "    balance roundrobin"                     # Distribute evenly across servers
    echo "    option tcp-check"                       # Health-check: try TCP connect

    # Add a "server" line for each control-plane IP.
    # The loop splits CPS by commas and creates entries like:
    #   server cp1 192.168.56.11:6443 check
    #   server cp2 192.168.56.12:6443 check
    # "check" means HAProxy will periodically test if the server is alive.
    i=1
    IFS=','                                           # Split on commas
    for ip in $CPS; do
      ip=$(echo "$ip" | tr -d ' ')                   # Remove any spaces around the IP
      echo "    server cp$i $ip:6443 check"           # Add the server to the backend
      i=$((i+1))                                      # Increment server counter
    done
    unset IFS                                         # Restore default field separator
  } | $SUDO tee -a /etc/haproxy/haproxy.cfg >/dev/null
  # tee -a = append to file (not overwrite)
  # >/dev/null = suppress tee's stdout (it prints what it writes)

  ok "Appended frontend/backend to /etc/haproxy/haproxy.cfg"
fi

# Validate the configuration file before restarting.
# haproxy -c = "check config only" — exits with error if syntax is wrong.
run "$SUDO haproxy -c -f /etc/haproxy/haproxy.cfg"

# Enable HAProxy to start automatically on boot.
# "systemctl enable" creates a symlink so systemd starts the service at boot.
run "$SUDO systemctl enable haproxy >/dev/null 2>&1"

# Restart HAProxy to apply the new configuration.
# "systemctl restart" stops the service (if running) and starts it again.
run "$SUDO systemctl restart haproxy"

# =============================================================================
# STAGE 3: Configure Keepalived (optional — only if DO_VIP=yes)
# =============================================================================
# Keepalived uses the VRRP protocol (Virtual Router Redundancy Protocol)
# to manage a "floating" Virtual IP (VIP) across multiple machines.
#
# HOW IT WORKS:
#   1. All LBs run Keepalived with the same VRID (virtual router ID).
#   2. They elect a MASTER based on priority (higher wins).
#   3. The MASTER assigns the VIP to its network interface.
#   4. The MASTER sends periodic "I'm alive" heartbeats.
#   5. If heartbeats stop, a BACKUP with the next-highest priority
#      takes over and claims the VIP. Failover happens in ~3 seconds.
if [ "$DO_VIP" = yes ]; then
  stage "Configuring Keepalived (floating VIP $VIP, $STATE)"

  # Write the keepalived.conf configuration file.
  # "cat <<EOF | sudo tee ..." is a "here document" — it lets you write
  # multi-line content inline in the script. Everything between <<EOF
  # and EOF is treated as the file content. Variables are expanded.
  cat <<EOF | $SUDO tee /etc/keepalived/keepalived.conf >/dev/null
# Health check script — runs every 2 seconds to verify HAProxy is alive.
# "killall -0 haproxy" sends signal 0 (a no-op) to haproxy. If haproxy
# is running, it succeeds (exit 0). If haproxy is dead, it fails (exit 1).
# When the check fails, this node's priority drops by "weight" (2),
# making a backup node take over the VIP.
vrrp_script chk_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight 2
}

# VRRP instance — one per VIP group. All LBs in the same group must
# have the same virtual_router_id and authentication.
vrrp_instance VI_1 {
    state $STATE
    interface $IFACE
    virtual_router_id $VRID
    priority $PRIO
    authentication {
        auth_type PASS
        auth_pass $VPASS
    }
    virtual_ipaddress {
        $VIP/24
    }
    track_script {
        chk_haproxy
    }
}
EOF

  ok "Wrote /etc/keepalived/keepalived.conf (interface=$IFACE, priority=$PRIO)"

  # Enable Keepalived to start automatically on boot
  run "$SUDO systemctl enable keepalived >/dev/null 2>&1"

  # Restart Keepalived to apply the new configuration
  run "$SUDO systemctl restart keepalived"
else
  # No Keepalived → the cluster has a single point of failure.
  warn "Single load balancer — no VIP failover. The control-plane endpoint is this node's IP."
fi

# =============================================================================
# STAGE 4: Verify that everything is working
# =============================================================================
stage "Verifying"

# Check that something is listening on port 6443.
# "ss -tlnp" shows:
#   -t = TCP sockets only
#   -l = listening sockets only
#   -n = show port numbers (not service names)
#   -p = show the process using each socket
# We grep for :6443 to confirm HAProxy is listening.
run "$SUDO ss -tlnp | grep ':6443' || true"

# If Keepalived is running and this is the MASTER, the VIP should appear
# on the network interface.
if [ "$DO_VIP" = yes ]; then
  info "If this is the MASTER, the VIP should appear here:"
  # "ip -4 addr show" lists IPv4 addresses on the specified interface.
  # We grep for the VIP to confirm it's been assigned.
  run "ip -4 addr show $IFACE | grep '$VIP' || true"
fi

echo   # Blank line for spacing
ok "${BLD}Load balancer ready.${RST}"
# Note: HAProxy's backend health checks will show the control planes as
# "DOWN" until they're actually set up. This is normal — you haven't
# run setup-controlplane.sh yet!
info "Backends show DOWN until the control planes are initialised — that is expected."
