#!/usr/bin/env bash
# setup-loadbalancer.sh — interactive, narrated HAProxy (+ Keepalived VIP) setup.
# Run on EACH load-balancer node:  curl -fsSL <URL>/setup-loadbalancer.sh | bash
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
confirm(){ local a; a=$(ask "$1 (y/n)" "${2:-y}"); case "$a" in y|Y|yes|YES) return 0;; *) return 1;; esac; }
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

printf '%s\n' "${BLU}${BLD}Kubernetes — Load Balancer Setup (HAProxy + Keepalived)${RST}"
echo "Fronts the API servers of all control planes behind one virtual IP (VIP)."
echo

# ---------- Stage 0: settings (with defaults from /vagrant/cluster.yaml if present) ----------
stage "Gathering settings"
DEF_VIP=""; DEF_CPS=""
if [ -f /vagrant/cluster.yaml ]; then
  DEF_VIP=$(grep -E '^vip:' /vagrant/cluster.yaml | grep -oE '([0-9]+\.){3}[0-9]+' | head -1 || true)
  DEF_CPS=$(grep 'k8s-cp' /vagrant/cluster.yaml | grep -oE '([0-9]+\.){3}[0-9]+' | paste -sd, -)
fi
VIP=$(ask "Virtual IP (VIP) for the API" "${DEF_VIP:-192.168.56.10}")
CPS=$(ask "Control-plane IPs (comma-separated)" "${DEF_CPS:-}")
[ -n "$CPS" ] || die "Enter at least one control-plane IP."
NODE_IP=$(hostname -I | tr ' ' '\n' | grep -vE '^(10\.0\.2\.|127\.|169\.254\.)' | head -1 || true)
IFACE=$(ip -o -4 addr show 2>/dev/null | awk -v ip="${NODE_IP:-x}" '$4 ~ "^"ip"/"{print $2; exit}')
IFACE=$(ask "Network interface that holds the VIP" "${IFACE:-eth1}")
DO_VIP=no
if confirm "Set up the Keepalived VIP on this node? (yes if you have 2+ load balancers)"; then DO_VIP=yes; fi
STATE=BACKUP; PRIO=100
if [ "$DO_VIP" = yes ]; then
  if confirm "Is this the PRIMARY (MASTER) load balancer?"; then STATE=MASTER; PRIO=101; fi
  VRID=$(ask "VRRP virtual_router_id (same on all LBs)" "51")
  VPASS=$(ask "VRRP shared password (same on all LBs)" "k8svip42")
fi

# ---------- Stage 1: install ----------
stage "Installing HAProxy${DO_VIP:+ and Keepalived}"
run "$SUDO apt-get update -y -q"
if [ "$DO_VIP" = yes ]; then run "$SUDO apt-get install -y -q haproxy keepalived psmisc"; else run "$SUDO apt-get install -y -q haproxy"; fi

# ---------- Stage 2: HAProxy config ----------
stage "Configuring HAProxy to balance the API servers"
if $SUDO grep -q 'kubernetes-api' /etc/haproxy/haproxy.cfg 2>/dev/null; then
  warn "An existing kubernetes-api block was found — leaving haproxy.cfg as-is."
else
  {
    echo ""
    echo "frontend kubernetes-api"
    echo "    bind *:6443"
    echo "    mode tcp"
    echo "    option tcplog"
    echo "    default_backend kube-apiservers"
    echo ""
    echo "backend kube-apiservers"
    echo "    mode tcp"
    echo "    balance roundrobin"
    echo "    option tcp-check"
    i=1; IFS=','; for ip in $CPS; do ip=$(echo "$ip" | tr -d ' '); echo "    server cp$i $ip:6443 check"; i=$((i+1)); done; unset IFS
  } | $SUDO tee -a /etc/haproxy/haproxy.cfg >/dev/null
  ok "Appended frontend/backend to /etc/haproxy/haproxy.cfg"
fi
run "$SUDO haproxy -c -f /etc/haproxy/haproxy.cfg"
run "$SUDO systemctl enable haproxy >/dev/null 2>&1"
run "$SUDO systemctl restart haproxy"

# ---------- Stage 3: Keepalived (optional) ----------
if [ "$DO_VIP" = yes ]; then
  stage "Configuring Keepalived (floating VIP $VIP, $STATE)"
  cat <<EOF | $SUDO tee /etc/keepalived/keepalived.conf >/dev/null
vrrp_script chk_haproxy {
    script "killall -0 haproxy"
    interval 2
    weight 2
}
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
  run "$SUDO systemctl enable keepalived >/dev/null 2>&1"
  run "$SUDO systemctl restart keepalived"
else
  warn "Single load balancer — no VIP failover. The control-plane endpoint is this node's IP."
fi

# ---------- Stage 4: verify ----------
stage "Verifying"
run "$SUDO ss -tlnp | grep ':6443' || true"
[ "$DO_VIP" = yes ] && { info "If this is the MASTER, the VIP should appear here:"; run "ip -4 addr show $IFACE | grep '$VIP' || true"; }
echo
ok "${BLD}Load balancer ready.${RST}"
info "Backends show DOWN until the control planes are initialised — that is expected."
