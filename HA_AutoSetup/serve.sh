#!/usr/bin/env bash
# serve.sh — serve the setup scripts over HTTP so the nodes can curl them.
# Run this on ONE reachable machine (e.g. your host or k8s-lb1), then on each
# node:  curl -fsSL http://<this-ip>:8000/setup-controlplane.sh | bash
set -euo pipefail
PORT="${1:-8000}"
DIR="$(cd "$(dirname "$0")" && pwd)"
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
echo "Serving $DIR on port $PORT"
echo "On each node, run one of:"
echo "  curl -fsSL http://$IP:$PORT/setup-loadbalancer.sh | bash"
echo "  curl -fsSL http://$IP:$PORT/setup-controlplane.sh | bash"
echo "  curl -fsSL http://$IP:$PORT/setup-worker.sh | bash"
echo "(Ctrl+C to stop)"
cd "$DIR"
exec python3 -m http.server "$PORT"
