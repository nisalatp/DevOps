#!/usr/bin/env bash
# =============================================================================
# configure.sh — Interactive Generator for cluster.yaml
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   This script asks you a series of questions about your desired Kubernetes
#   cluster layout — how many load balancers, control planes, workers,
#   which IPs to use, how much RAM per VM, etc. — and then writes all
#   your answers into a file called "cluster.yaml".
#
#   The Vagrantfile reads cluster.yaml to know what VMs to create.
#   So the workflow is:   ./configure.sh  →  cluster.yaml  →  vagrant up
#
# HOW TO RUN:
#   cd HA_AutoSetup
#   ./configure.sh        # follow the interactive prompts
#
# WHAT YOU'LL LEARN:
#   - How bash reads user input and provides default values
#   - How YAML configuration files drive infrastructure-as-code
#   - Why control planes must be an odd number (quorum)
#   - How IP addressing works in a private Kubernetes cluster
# =============================================================================

# ---- Shell safety settings ----
# "set -euo pipefail" is a best-practice combo for robust scripts:
#   -e  = exit immediately if ANY command fails (non-zero exit code)
#   -u  = treat unset variables as errors (catches typos like $NAEM)
#   -o pipefail = if any command in a pipe (cmd1 | cmd2) fails, the whole
#                 pipe fails, not just the last command
set -euo pipefail

# ---- Define colour codes for pretty terminal output ----
# The function c() generates ANSI escape sequences.
# ANSI escapes are special character sequences that tell the terminal
# to change text colour, make it bold, etc.
# The format is:  \033[<code>m   where <code> is a number like 1;36
c(){ printf '\033[%sm' "$1"; }

# Now we create named colour variables by calling c() with different codes:
# "1;" means bold, the second number is the colour.
BLU=$(c '1;36')   # Bold Cyan    — used for titles and headings
GRN=$(c '1;32')   # Bold Green   — used for success messages
YLW=$(c '0;33')   # Yellow       — used for warnings (0; = not bold)
RED=$(c '1;31')   # Bold Red     — used for errors (not used here but available)
BLD=$(c '1')      # Bold (white) — used to emphasise text without colour
RST=$(c '0')      # Reset        — turns OFF all formatting, back to normal text

# ---- Helper functions for user interaction ----

# info() — prints an indented message (3 spaces for visual nesting)
# Usage:  info "some message"
info(){ printf '   %s\n' "$*"; }

# ok() — prints a green checkmark (✓) followed by a success message
# \xe2\x9c\x93 is the UTF-8 byte sequence for the ✓ character.
ok(){ printf '   %s\xe2\x9c\x93 %s%s\n' "$GRN" "$*" "$RST"; }

# ask() — prompts the user for input, with an optional default value.
#
# How it works step by step:
#   $1 = the prompt text (e.g., "How many workers?")
#   $2 = the default value (optional, shown in [brackets])
#   - We print the prompt to /dev/tty (the real terminal), not stdout,
#     so this function works even if the script's stdout is redirected.
#   - We read the user's answer into variable "a".
#   - If the user just presses Enter (empty input), we use the default.
#   - The final printf outputs the chosen value (for the caller to capture).
#
# Example usage:  SUBNET=$(ask "Enter subnet" "192.168.56")
#   If the user types "10.0.0", SUBNET becomes "10.0.0"
#   If the user just presses Enter, SUBNET becomes "192.168.56"
ask(){
  local p="$1" d="${2:-}" a           # p=prompt, d=default, a=answer
  if [ -n "$d" ]; then                # If a default value was provided...
    printf '%s [%s]: ' "$p" "$d" >/dev/tty   # show "Prompt [default]: "
  else
    printf '%s: ' "$p" >/dev/tty             # show "Prompt: " (no default)
  fi
  IFS= read -r a </dev/tty || true   # Read the user's input from the terminal
  # IFS=  preserves leading/trailing whitespace in the answer
  # -r    prevents backslash interpretation (treats \ literally)
  # </dev/tty  reads from the terminal even if stdin is redirected
  # || true    prevents the script from exiting if read hits EOF
  printf '%s' "${a:-$d}"              # Output the answer, or the default if empty
}

# =============================================================================
# MAIN SCRIPT — ask questions, then write cluster.yaml
# =============================================================================

# Print the title banner
printf '%s\n' "${BLU}${BLD}Kubernetes HA Cluster — interactive configurator${RST}"
echo "Answer a few questions; this writes cluster.yaml for Vagrant. Press Enter to accept [defaults]."
echo   # Blank line for visual spacing

# ---------- QUESTION 1: Subnet ----------
# A "subnet" is a range of IP addresses on the same local network.
# "192.168.56" means all IPs will be 192.168.56.X where X is 1-254.
# This is used by VirtualBox's host-only network so your VMs can
# talk to each other (and to your laptop) on a private LAN.
SUBNET=$(ask "Subnet — first three octets (host-only /24)" "192.168.56")

# ---------- QUESTION 2: Number of load balancers ----------
# Load balancers sit in front of the control planes and distribute
# API requests evenly. We use HAProxy for this.
# "while :; do ... done" is an infinite loop; it keeps asking until
# the user gives a valid answer (1, 2, or 3).
# The regex ^[1-3]$ matches exactly one digit that is 1, 2, or 3.
while :; do
  NLB=$(ask "How many LOAD BALANCERS? (1-3)" "2")
  [[ "$NLB" =~ ^[1-3]$ ]] && break   # Valid input → exit the loop
  info "${YLW}Please enter 1, 2 or 3.${RST}"
done

# ---------- QUESTION 3: Number of control planes ----------
# Control planes run the Kubernetes "brain" — the API server, scheduler,
# controller-manager, and etcd (the cluster database).
#
# WHY ODD NUMBERS? Kubernetes uses etcd, which needs a "quorum" (majority
# of nodes agree) to accept writes. With 3 nodes, 2 must agree (tolerates
# 1 failure). With 5 nodes, 3 must agree (tolerates 2 failures).
# Even numbers don't improve fault tolerance: 4 nodes still only
# tolerates 1 failure (same as 3), but wastes an extra machine.
while :; do
  NCP=$(ask "How many CONTROL PLANES? (odd: 1,3,5,7)" "3")
  [[ "$NCP" =~ ^(1|3|5|7)$ ]] && break   # Valid input → exit the loop
  info "${YLW}Control planes must be odd (1,3,5,7) so etcd keeps quorum.${RST}"
done

# ---------- QUESTION 4: Number of workers ----------
# Workers are the nodes that actually run your application containers
# (Pods). You can have 0 workers (control planes can run Pods too,
# but that's not recommended in production).
while :; do
  NWK=$(ask "How many WORKER nodes? (0-9)" "2")
  [[ "$NWK" =~ ^[0-9]$ ]] && break   # Valid input → exit the loop
  info "${YLW}Please enter 0-9.${RST}"
done

# ---------- QUESTIONS 5-8: IP address assignments ----------
# Each role gets a range of IPs within the subnet.
# The "octet" is the last number in the IP (e.g., .10 in 192.168.56.10).
#
# VIP (Virtual IP) = a "floating" IP that Keepalived moves between
# load balancers. Clients always connect to this one address, and
# Keepalived ensures it's always assigned to a healthy load balancer.
VIP_H=$(ask "VIP host octet (the floating API address)" "10")

# Load balancers start at .5 by default (so lb1=.5, lb2=.6, etc.)
LB_S=$(ask "Load-balancer start octet" "5")

# Control planes start at .11 by default (so cp1=.11, cp2=.12, cp3=.13)
CP_S=$(ask "Control-plane start octet" "11")

# Workers start at .21 by default (so w1=.21, w2=.22, etc.)
WK_S=$(ask "Worker start octet" "21")

# ---------- QUESTION 9: Base box (VM image) ----------
# A "box" in Vagrant is a pre-built VM image (like an ISO for VirtualBox).
# Different boxes have different sizes and OS versions. We print a menu
# and let the user choose.
#
# The { ... } >/dev/tty block prints the menu to the terminal directly,
# bypassing any output redirection (ensures the menu is always visible).
{
  printf '\n%sChoose a base box%s (smaller = more VMs fit on your laptop):\n' "$BLD" "$RST"
  printf '  1) bento/debian-12      Debian 12 minimal   ~120 MB idle, ~2 GB disk   [recommended]\n'
  printf '  2) bento/ubuntu-24.04   Ubuntu 24.04 LTS    ~200 MB idle  (familiar)\n'
  printf '  3) bento/ubuntu-22.04   Ubuntu 22.04 LTS    ~200 MB idle  (matches the courses)\n'
  printf '  4) generic/debian12     Debian 12 (roboxes) fallback if bento is unavailable\n'
} >/dev/tty

# Read the user's choice (1-4 or a custom box name)
BCHOICE=$(ask "Box choice (1-4, or type any box name)" "1")

# Map the number choice to the actual box name using a "case" statement.
# case is like a switch/if-else — it matches patterns and runs the
# corresponding code block, ending each with ";;".
case "$BCHOICE" in
  1) BOX="bento/debian-12" ;;       # Recommended: small footprint
  2) BOX="bento/ubuntu-24.04" ;;    # Ubuntu LTS if you prefer it
  3) BOX="bento/ubuntu-22.04" ;;    # Older Ubuntu, matches some courses
  4) BOX="generic/debian12" ;;      # Fallback Debian image
  *) BOX="$BCHOICE" ;;              # User typed a custom box name
esac

# Show which box was selected
info "Box: ${GRN}$BOX${RST}"

# ---------- QUESTIONS 10-12: Kubernetes and CNI versions ----------

# Kubernetes version — the minor version (e.g., v1.36) determines which
# apt repository to use when installing kubeadm/kubelet/kubectl.
K8S=$(ask "Kubernetes version (minor)" "v1.36")

# Pod CIDR — the internal IP range used for Pods (containers).
# This MUST NOT overlap with your VM subnet (192.168.56.0/24) or your
# home network. 10.244.0.0/16 gives ~65,000 Pod IPs, which is plenty.
PODCIDR=$(ask "Pod network CIDR (must NOT overlap your subnet)" "10.244.0.0/16")

# Calico version — Calico is the CNI (Container Network Interface) plugin
# that handles Pod-to-Pod networking across nodes. It creates virtual
# network routes so containers on different VMs can reach each other.
CALICO=$(ask "Calico version" "v3.29.1")

# ---------- QUESTIONS 13-15: Per-VM RAM allocation ----------
echo   # Blank line for visual spacing
info "Per-VM memory in MB — all VMs run at once, so keep your host's RAM in mind:"

# Load balancers only run HAProxy + Keepalived, so they need very little RAM.
LBMEM=$(ask "  Load-balancer RAM" "512")

# Control planes run etcd + API server + scheduler + controller-manager.
# At least 1800 MB is recommended; 2048 MB (2 GB) is a safe default.
CPMEM=$(ask "  Control-plane RAM (>=1800 recommended)" "2048")

# Workers run your application Pods, so their RAM depends on your workload.
# 1536 MB (1.5 GB) is enough for a lab environment.
WKMEM=$(ask "  Worker RAM" "1536")

# =============================================================================
# WRITE cluster.yaml — the file that drives everything
# =============================================================================

# Determine the output path: same directory as this script, file named cluster.yaml.
# $(dirname "$0") returns the directory where this script lives.
OUT="$(dirname "$0")/cluster.yaml"

# The { ... } > "$OUT" block redirects all output inside the braces into
# the file. Each "echo" line writes one line of YAML.
{
  # Header comment so users know this file was auto-generated.
  echo "# Generated by configure.sh — edit by re-running it, or by hand."

  # Write each YAML key-value pair.
  # The \" inside the echo adds literal quotes around the values in YAML,
  # which ensures they're treated as strings (not numbers or booleans).
  echo "subnet: \"$SUBNET\""
  echo "vip: \"$SUBNET.$VIP_H\""
  echo "box: \"$BOX\""
  echo "k8s_version: \"$K8S\""
  echo "pod_cidr: \"$PODCIDR\""
  echo "calico_version: \"$CALICO\""

  # Resource allocation section — nested YAML with inline syntax { key: value }.
  echo "resources:"
  echo "  lb: { memory: $LBMEM, cpus: 1 }"
  echo "  cp: { memory: $CPMEM, cpus: 2 }"
  echo "  wk: { memory: $WKMEM, cpus: 1 }"

  # --- Generate the load_balancers list ---
  # "seq 1 $NLB" produces numbers 1, 2, ..., NLB
  # For each number i, we calculate the IP as: SUBNET.(LB_START + i - 1)
  # Example with LB_S=5 and NLB=2:
  #   i=1 → IP = 192.168.56.5, name = k8s-lb1
  #   i=2 → IP = 192.168.56.6, name = k8s-lb2
  echo "load_balancers:"
  for i in $(seq 1 "$NLB"); do
    echo "  - { name: k8s-lb$i, ip: $SUBNET.$((LB_S + i - 1)) }"
  done

  # --- Generate the control_planes list ---
  # Same pattern as load balancers, but with CP_S as the start octet.
  echo "control_planes:"
  for i in $(seq 1 "$NCP"); do
    echo "  - { name: k8s-cp$i, ip: $SUBNET.$((CP_S + i - 1)) }"
  done

  # --- Generate the workers list ---
  # If the user chose 0 workers, write an empty YAML list "[]".
  echo "workers:"
  if [ "$NWK" -gt 0 ]; then
    for i in $(seq 1 "$NWK"); do
      echo "  - { name: k8s-w$i, ip: $SUBNET.$((WK_S + i - 1)) }"
    done
  else
    echo "  []"   # Empty YAML list — no worker nodes
  fi
} > "$OUT"   # All the echo output above is written to cluster.yaml

# =============================================================================
# DISPLAY A SUMMARY TABLE — so the user can verify their choices
# =============================================================================

echo   # Blank line
ok "Wrote $OUT"
echo

# Print a formatted table of all planned nodes.
# printf '%-10s' left-aligns text in a 10-character-wide column.
printf '%s%s\n' "$BLD" "Planned cluster:${RST}"
printf '   %-10s %-26s %s\n' "ROLE" "HOSTNAME" "IP"

# First row: the VIP (Virtual IP), which is not a real VM but a floating address.
printf '   %-10s %-26s %s\n' "VIP" "k8s-vip" "$SUBNET.$VIP_H"

# Print each load balancer with its name and calculated IP.
for i in $(seq 1 "$NLB"); do
  printf '   %-10s %-26s %s\n' "loadbal" "k8s-lb$i" "$SUBNET.$((LB_S + i - 1))"
done

# Print each control plane with its name and calculated IP.
for i in $(seq 1 "$NCP"); do
  printf '   %-10s %-26s %s\n' "control" "k8s-cp$i" "$SUBNET.$((CP_S + i - 1))"
done

# Print each worker (if any) with its name and calculated IP.
if [ "$NWK" -gt 0 ]; then
  for i in $(seq 1 "$NWK"); do
    printf '   %-10s %-26s %s\n' "worker" "k8s-w$i" "$SUBNET.$((WK_S + i - 1))"
  done
fi

# =============================================================================
# MEMORY ESTIMATE — warn if the cluster needs too much RAM
# =============================================================================

# Calculate total VM memory:  (num_LBs × LB_RAM) + (num_CPs × CP_RAM) + (num_Workers × WK_RAM)
# $(( )) is bash arithmetic — it does integer math inside double parentheses.
TOTMEM=$(( NLB*LBMEM + NCP*CPMEM + NWK*WKMEM ))

echo   # Blank line
info "Estimated VM memory: ${BLD}${TOTMEM} MB${RST}  (${NLB}x${LBMEM} + ${NCP}x${CPMEM} + ${NWK}x${WKMEM}). Leave a few GB free for your host."

# If total VM RAM exceeds 12 GB, warn the user that their laptop might struggle.
# 12288 MB = 12 GB.
[ "$TOTMEM" -gt 12288 ] && info "${YLW}That's heavy — consider fewer nodes or less RAM per node.${RST}"

# =============================================================================
# NEXT STEPS — tell the user what to do after this script finishes
# =============================================================================

echo   # Blank line
echo "Next:  ${GRN}vagrant up${RST}   then follow README.md to run the setup scripts on each node."

# Extra warning if only 1 load balancer — no VIP failover means the LB is a
# "single point of failure" (SPOF). If it goes down, the whole cluster is
# unreachable. Using 2+ load balancers with Keepalived eliminates this SPOF.
[ "$NLB" -lt 2 ] && info "${YLW}Note: with 1 load balancer there is no VIP failover (single point of failure). Use 2+ for true HA.${RST}"

# Exit cleanly with status code 0 (success).
exit 0
