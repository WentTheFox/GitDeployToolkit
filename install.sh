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
install -m 0755 "$SRC_DIR/share/git-deploy-notify" "$LIB_DIR/git-deploy-notify"
# Optional per-repo logrotate definitions (deploy.logrotate). Only ever
# invoked through the sudoers rule printed below; harmless until then.
install -m 0755 "$SRC_DIR/share/git-deploy-logrotate" "$LIB_DIR/git-deploy-logrotate"
install -m 0755 "$SRC_DIR/bin/git-deploy-new" "$BIN_DIR/git-deploy-new"

# Optional GitHub deployment webhook listener. Installing these files is
# harmless on a server that doesn't use it — the unit does nothing until
# someone runs `systemctl enable --now git-deploy-webhook@<deploy-user>`.
install -m 0755 "$SRC_DIR/share/git-deploy-webhook" "$LIB_DIR/git-deploy-webhook"
install -m 0644 "$SRC_DIR/share/webhook-hooks.json" "$LIB_DIR/hooks.json"
install -m 0644 "$SRC_DIR/share/git-deploy-webhook@.service" /etc/systemd/system/git-deploy-webhook@.service
systemctl daemon-reload 2> /dev/null || true
# Pick up hook/script changes in an already-running listener.
systemctl try-restart 'git-deploy-webhook@*.service' 2> /dev/null || true

mkdir -p /srv/git

echo "git-deploy-toolkit installed:"
echo "  hook:   $LIB_DIR/post-receive"
echo "  helper: $BIN_DIR/git-deploy-new"
echo "  webhook (optional): $LIB_DIR/git-deploy-webhook, git-deploy-webhook@.service"
echo "  logrotate (optional): $LIB_DIR/git-deploy-logrotate — for apps with a deploy.logrotate, allow it with"
echo "    <deploy-user> ALL=(root) NOPASSWD: $LIB_DIR/git-deploy-logrotate install *"
echo "    in /etc/sudoers.d/git-deploy-logrotate (mode 0440). See README."
echo
echo "Create a new app with: git-deploy-new <app-name> [worktree-path] [branch]"
