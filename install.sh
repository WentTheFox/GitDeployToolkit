#!/usr/bin/env bash
# Run once per server (VPS). Installs the shared hook and the
# git-deploy-new helper. Safe to re-run to pick up toolkit updates.
#
# Usage: sudo ./install.sh

set -euo pipefail

LIB_DIR="/usr/local/lib/git-deploy"
BIN_DIR="/usr/local/bin"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $EUID -ne 0 ]]; then
  echo "install.sh: run as root (sudo ./install.sh)" >&2
  exit 1
fi

install -d "$LIB_DIR"
install -m 0755 "$SRC_DIR/share/post-receive" "$LIB_DIR/post-receive"
install -m 0755 "$SRC_DIR/bin/git-deploy-new" "$BIN_DIR/git-deploy-new"

mkdir -p /srv/git

echo "git-deploy-toolkit installed:"
echo "  hook:   $LIB_DIR/post-receive"
echo "  helper: $BIN_DIR/git-deploy-new"
echo
echo "Create a new app with: git-deploy-new <app-name> [worktree-path] [branch]"
