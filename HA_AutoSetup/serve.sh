#!/usr/bin/env bash
# =============================================================================
# serve.sh — Serve the Setup Scripts Over HTTP (Simple File Server)
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Starts a simple HTTP file server so that other machines (the Vagrant VMs)
#   can download the setup scripts using curl. This is useful when:
#     - You don't have a GitHub repo yet (use publish.sh for that)
#     - You want to iterate quickly without pushing to GitHub every time
#     - You're in an air-gapped (no internet) environment
#
# HOW IT WORKS:
#   1. Starts Python's built-in HTTP server on port 8000 (or custom port)
#   2. Serves all files in the HA_AutoSetup directory
#   3. On each VM, you can then run:
#        curl -fsSL http://<this-ip>:8000/setup-worker.sh | bash
#
# HOW TO RUN:
#   ./serve.sh           # serves on port 8000 (default)
#   ./serve.sh 9090      # serves on port 9090 (custom)
#
# PREREQUISITES:
#   - Python 3 must be installed (comes pre-installed on most Linux/macOS)
#
# NOTE:
#   Run this on a machine that is reachable from all cluster nodes
#   (e.g., your host machine, or k8s-lb1).
#   Press Ctrl+C to stop the server when you're done.
# =============================================================================

# ---- Shell safety settings ----
# -e  = exit immediately if ANY command fails
# -u  = treat unset variables as errors
# -o pipefail = if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# ---- Configuration ----
# ${1:-8000} means "use the first command-line argument ($1), or 8000
# if no argument was provided". This is a bash "default value" syntax.
# So:  ./serve.sh      →  PORT=8000
#      ./serve.sh 9090  →  PORT=9090
PORT="${1:-8000}"

# Get the absolute path to the directory containing this script.
# $(dirname "$0") gives the directory part of the script's path.
# cd + pwd converts it to an absolute path (resolving any relative paths).
DIR="$(cd "$(dirname "$0")" && pwd)"

# Detect this machine's IP address so we can tell the user what URL to use.
# "hostname -I" lists all IP addresses. "awk '{print $1}'" takes just the first one.
# 2>/dev/null suppresses errors on systems where hostname -I isn't supported.
IP=$(hostname -I 2>/dev/null | awk '{print $1}')

# ---- Print usage instructions ----
echo "Serving $DIR on port $PORT"
echo "On each node, run one of:"
echo "  curl -fsSL http://$IP:$PORT/setup-loadbalancer.sh | bash"
echo "  curl -fsSL http://$IP:$PORT/setup-controlplane.sh | bash"
echo "  curl -fsSL http://$IP:$PORT/setup-worker.sh | bash"
echo "(Ctrl+C to stop)"

# ---- Start the HTTP server ----
# First, change to the script's directory so Python serves files from there.
cd "$DIR"

# "exec" replaces the current shell process with the Python server.
# This means:
#   - The Python process inherits this script's PID
#   - Ctrl+C goes directly to Python (clean shutdown)
#   - No extra bash process hanging around using memory
#
# "python3 -m http.server" starts Python's built-in HTTP server module.
# It serves all files in the current directory (and subdirectories) over HTTP.
# This is a simple, single-threaded server — perfect for a lab environment
# but NOT suitable for production use.
exec python3 -m http.server "$PORT"
