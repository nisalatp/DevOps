#!/usr/bin/env bash
# publish.sh — push this folder to a NEW public GitHub repo.
# Run on YOUR machine (where you're logged into GitHub).
#   * If you have the GitHub CLI (gh), it creates the repo and pushes.
#   * Otherwise it prints the exact git commands to finish by hand.
set -euo pipefail
GRN=$'\033[1;32m'; YLW=$'\033[0;33m'; BLD=$'\033[1m'; RST=$'\033[0m'
ask(){ local p="$1" d="${2:-}" a; printf '%s [%s]: ' "$p" "$d" >/dev/tty; IFS= read -r a </dev/tty || true; printf '%s' "${a:-$d}"; }

DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$DIR"
command -v git >/dev/null || { echo "git is not installed."; exit 1; }

NAME=$(ask "New public repo name" "k8s-cluster-builder")

git init -q 2>/dev/null || true
git add .
git commit -q -m "cluster-builder: HA Kubernetes lab (Vagrant + interactive setup scripts)" 2>/dev/null || true
git branch -M main

if command -v gh >/dev/null; then
  echo "${BLD}Creating public repo '$NAME' and pushing...${RST}"
  gh repo create "$NAME" --public --source=. --remote=origin --push
  USER=$(gh api user -q .login 2>/dev/null || echo '<you>')
  echo
  echo "${GRN}Done.${RST} Your scripts are now at:"
  echo "  https://raw.githubusercontent.com/$USER/$NAME/main/setup-loadbalancer.sh"
  echo "  https://raw.githubusercontent.com/$USER/$NAME/main/setup-controlplane.sh"
  echo "  https://raw.githubusercontent.com/$USER/$NAME/main/setup-worker.sh"
else
  echo "${YLW}GitHub CLI (gh) not found.${RST} Finish in two steps:"
  echo "  1) Create an EMPTY public repo named '$NAME' at https://github.com/new"
  echo "  2) Run:"
  echo "       git remote add origin https://github.com/<you>/$NAME.git"
  echo "       git push -u origin main"
  echo
  echo "Then your scripts are at:"
  echo "  https://raw.githubusercontent.com/<you>/$NAME/main/setup-worker.sh"
fi
