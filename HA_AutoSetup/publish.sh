#!/usr/bin/env bash
# =============================================================================
# publish.sh — Push This Folder to a NEW Public GitHub Repository
# =============================================================================
#
# WHAT THIS SCRIPT DOES:
#   Packages the HA_AutoSetup folder into a new GitHub repository and pushes
#   it so the setup scripts become curl-able from anywhere:
#     curl -fsSL https://raw.githubusercontent.com/<you>/<repo>/main/setup-worker.sh | bash
#
#   Two modes:
#     A) If you have the GitHub CLI (gh) installed → creates the repo and
#        pushes automatically.
#     B) If you don't have gh → prints the exact git commands to finish
#        by hand.
#
# HOW TO RUN:
#   Run this on YOUR machine (where you're logged into GitHub), NOT inside
#   a Vagrant VM:
#     cd HA_AutoSetup
#     ./publish.sh
#
# PREREQUISITES:
#   - git must be installed
#   - (Optional) GitHub CLI (gh) for fully automated publish
# =============================================================================

# ---- Shell safety settings ----
# -e  = exit immediately if ANY command fails
# -u  = treat unset variables as errors
# -o pipefail = if any command in a pipe fails, the whole pipe fails
set -euo pipefail

# ---- Define colour codes for output ----
# Using $'...' syntax which interprets escape sequences at assignment time.
# This is a bash feature — $'\033[1;32m' directly creates the escape sequence
# (unlike the c() function used in other scripts, which calls printf).
GRN=$'\033[1;32m'  # Bold Green   — success messages
YLW=$'\033[0;33m'  # Yellow       — warnings
BLD=$'\033[1m'     # Bold (white) — emphasis
RST=$'\033[0m'     # Reset        — back to normal text

# ---- ask() helper ----
# Simplified version of the ask function from the other scripts.
# This one always shows a default (no "no default" branch needed here).
ask(){
  local p="$1" d="${2:-}" a           # p=prompt, d=default, a=answer
  printf '%s [%s]: ' "$p" "$d" >/dev/tty  # Show "Prompt [default]: " on terminal
  IFS= read -r a </dev/tty || true   # Read the user's answer
  printf '%s' "${a:-$d}"              # Output the answer, or default if blank
}

# ---- Change to the script's directory ----
# $(dirname "$0") returns the directory containing this script.
# cd into it so all git operations happen in the right folder.
# pwd prints the absolute path, which we store in DIR.
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

# ---- Check that git is installed ----
# "command -v git" checks if the "git" command exists in PATH.
# If it doesn't, we print an error and exit.
command -v git >/dev/null || { echo "git is not installed."; exit 1; }

# ---- Ask for the repository name ----
NAME=$(ask "New public repo name" "k8s-cluster-builder")

# =============================================================================
# Initialise git and create the first commit
# =============================================================================

# "git init -q" initialises a new git repository in the current directory.
# -q = quiet (less output). 2>/dev/null suppresses "already initialized" warnings.
git init -q 2>/dev/null || true

# Stage all files for commit.
# "git add ." adds all files in the current directory (and subdirectories).
git add .

# Create the first commit with a descriptive message.
# -q = quiet. -m = commit message inline.
# 2>/dev/null || true = silently ignore "nothing to commit" errors.
git commit -q -m "cluster-builder: HA Kubernetes lab (Vagrant + interactive setup scripts)" 2>/dev/null || true

# Rename the default branch to "main" (GitHub's standard).
# -M = move/rename, forced (overwrite if "main" already exists).
# Older git versions create a "master" branch; this ensures consistency.
git branch -M main

# =============================================================================
# Publish to GitHub
# =============================================================================

# Check if the GitHub CLI (gh) is installed.
if command -v gh >/dev/null; then
  # ---- Option A: Fully automated with GitHub CLI ----
  echo "${BLD}Creating public repo '$NAME' and pushing...${RST}"

  # "gh repo create" creates a new repository on GitHub and pushes code.
  #   --public     = make the repo publicly visible (anyone can clone/view)
  #   --source=.   = use the current directory as the source
  #   --remote=origin = name the remote "origin" (the standard name)
  #   --push       = push the code immediately after creating the repo
  gh repo create "$NAME" --public --source=. --remote=origin --push

  # Get the authenticated GitHub username for display purposes.
  # "gh api user -q .login" queries the GitHub API for the current user
  # and extracts just the login name using jq-style filtering (-q).
  USER=$(gh api user -q .login 2>/dev/null || echo '<you>')

  echo   # Blank line for spacing

  # Show the raw.githubusercontent.com URLs for each setup script.
  # These URLs serve the file content directly (no HTML wrapper), so
  # they can be piped to bash: curl -fsSL <url> | bash
  echo "${GRN}Done.${RST} Your scripts are now at:"
  echo "  https://raw.githubusercontent.com/$USER/$NAME/main/setup-loadbalancer.sh"
  echo "  https://raw.githubusercontent.com/$USER/$NAME/main/setup-controlplane.sh"
  echo "  https://raw.githubusercontent.com/$USER/$NAME/main/setup-worker.sh"
else
  # ---- Option B: Manual instructions (no GitHub CLI) ----
  echo "${YLW}GitHub CLI (gh) not found.${RST} Finish in two steps:"
  echo "  1) Create an EMPTY public repo named '$NAME' at https://github.com/new"
  echo "  2) Run:"
  echo "       git remote add origin https://github.com/<you>/$NAME.git"
  echo "       git push -u origin main"
  echo
  echo "Then your scripts are at:"
  echo "  https://raw.githubusercontent.com/<you>/$NAME/main/setup-worker.sh"
fi
