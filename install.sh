#!/usr/bin/env bash
# Run once per server (VPS). Installs the shared hook and the
# git-deploy-new helper. Safe to re-run to pick up toolkit updates.
#
# Usage: sudo ./install.sh [--deploy-user NAME]
#
# With --deploy-user (remembered in /etc/git-deploy/user, so a plain re-run
# or git-deploy-update keeps it) this also writes /etc/sudoers.d/git-deploy:
# the narrow set of root commands that user's deploys may run. Without it,
# nothing about sudo is touched. See docs/deploy-user.md.

set -euo pipefail

LIB_DIR="/usr/local/lib/git-deploy"
BIN_DIR="/usr/local/bin"
SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="${GIT_DEPLOY_ETC:-/etc/git-deploy}"
SUDOERS_FILE="${GIT_DEPLOY_SUDOERS_FILE:-/etc/sudoers.d/git-deploy}"
WEB_USER="${GIT_DEPLOY_WEB_USER:-www-data}"
DEPLOY_USER=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --deploy-user) DEPLOY_USER="${2:?install.sh: --deploy-user needs a name}"; shift 2 ;;
    *) echo "install.sh: unknown argument $1" >&2; exit 2 ;;
  esac
done

if [[ $EUID -ne 0 ]]; then
  echo "install.sh: run as root (sudo ./install.sh)" >&2
  exit 1
fi

install -d "$LIB_DIR"
install -m 0755 "$SRC_DIR/share/post-receive" "$LIB_DIR/post-receive"
install -m 0755 "$SRC_DIR/share/git-deploy-notify" "$LIB_DIR/git-deploy-notify"
install -m 0755 "$SRC_DIR/share/pre-receive" "$LIB_DIR/pre-receive"
# Optional per-repo logrotate definitions (deploy.logrotate). Only ever
# invoked through the sudoers rule printed below; harmless until then.
install -m 0755 "$SRC_DIR/share/git-deploy-logrotate" "$LIB_DIR/git-deploy-logrotate"
# Same idea for scheduled jobs (deploy.cron).
install -m 0755 "$SRC_DIR/share/git-deploy-cron" "$LIB_DIR/git-deploy-cron"
# Root-side replacements for the `sudo chgrp/chmod/find` and `sudo systemctl`
# lines a deploy.conf used to need (a free-form version of either is root).
install -m 0755 "$SRC_DIR/share/git-deploy-fixperms" "$LIB_DIR/git-deploy-fixperms"
install -m 0755 "$SRC_DIR/share/git-deploy-service" "$LIB_DIR/git-deploy-service"
install -m 0755 "$SRC_DIR/bin/git-deploy-new" "$BIN_DIR/git-deploy-new"
install -m 0755 "$SRC_DIR/bin/git-deploy-update" "$BIN_DIR/git-deploy-update"
# Read-only health check of the deploy-user setup (sudo git-deploy-check).
install -m 0755 "$SRC_DIR/bin/git-deploy-check" "$BIN_DIR/git-deploy-check"
# Optional release directories (RELEASES=1): rollback, and the one-time conversion.
install -m 0755 "$SRC_DIR/bin/git-deploy-rollback" "$BIN_DIR/git-deploy-rollback"
install -m 0755 "$SRC_DIR/bin/git-deploy-releases-init" "$BIN_DIR/git-deploy-releases-init"
# Where git-deploy-update finds the clone to pull.
printf '%s\n' "$SRC_DIR" > "$LIB_DIR/source"

# Optional GitHub deployment webhook listener. Installing these files is
# harmless on a server that doesn't use it — the unit does nothing until
# someone runs `systemctl enable --now git-deploy-webhook@<deploy-user>`.
install -m 0755 "$SRC_DIR/share/git-deploy-webhook" "$LIB_DIR/git-deploy-webhook"
install -m 0644 "$SRC_DIR/share/webhook-hooks.json" "$LIB_DIR/hooks.json"
install -m 0644 "$SRC_DIR/share/git-deploy-webhook@.service" /etc/systemd/system/git-deploy-webhook@.service
systemctl daemon-reload 2> /dev/null || true
# Pick up hook/script changes in an already-running listener.
systemctl try-restart 'git-deploy-webhook@*.service' 2> /dev/null || true

REPO_ROOT="${GIT_DEPLOY_REPO_ROOT:-/srv/git}"
mkdir -p "$REPO_ROOT"

# --- the dedicated deploy user's sudo rights --------------------------------
install -d -m 0755 "$ETC_DIR"
[[ -z "$DEPLOY_USER" && -f "$ETC_DIR/user" ]] && DEPLOY_USER="$(head -n1 "$ETC_DIR/user")"
SUDO_STATUS="not managed (no deploy user given; pass --deploy-user NAME to have it written)"
PM2_STATUS="not installed (needs --deploy-user)"
if [[ -n "$DEPLOY_USER" ]]; then
  [[ "$DEPLOY_USER" =~ ^[a-z_][a-z0-9_-]*$ && "$DEPLOY_USER" != root ]] \
    || { echo "install.sh: '$DEPLOY_USER' is not a usable deploy user name" >&2; exit 1; }
  id -u "$DEPLOY_USER" > /dev/null 2>&1 \
    || { echo "install.sh: user '$DEPLOY_USER' does not exist (see docs/deploy-user.md)" >&2; exit 1; }
  printf '%s\n' "$DEPLOY_USER" > "$ETC_DIR/user"
  chmod 0644 "$ETC_DIR/user"
  # The service allow-list the root helper reads. Seeded once, never overwritten.
  if [[ ! -e "$ETC_DIR/services" ]]; then
    cat > "$ETC_DIR/services" <<'SERVICES'
# Services a deploy may restart or reload via git-deploy-service. One rule per
# line: <action>[,<action>...] <unit-pattern>   (actions: restart, reload,
# try-restart, reload-or-restart). Root-owned; nothing else may write it.
# reload php*-fpm.service
# restart myapp-horizon.service
SERVICES
    chmod 0644 "$ETC_DIR/services"
  fi
  # Refuse pushes from anyone but the deploy user, in every existing bare repo
  # (git-deploy-new does the same for new ones). Only repos on our hook.
  for repo in "$REPO_ROOT"/*.git; do
    [[ -L "$repo/hooks/post-receive" && "$(readlink "$repo/hooks/post-receive")" == "$LIB_DIR/post-receive" ]] || continue
    ln -sfn "$LIB_DIR/pre-receive" "$repo/hooks/pre-receive"
  done
  TMP="$(mktemp)"
  cat > "$TMP" <<SUDOERS
# Managed by git-deploy-toolkit install.sh — regenerated on every run; change
# $ETC_DIR/* instead of this file. See docs/deploy-user.md.
#
# Root commands: exactly these helpers, each of which validates its own
# arguments (a repo controls them). No shell, no systemctl, no chmod/chgrp.
$DEPLOY_USER ALL=(root) NOPASSWD: \\
    $LIB_DIR/git-deploy-service *, \\
    $LIB_DIR/git-deploy-fixperms *, \\
    $LIB_DIR/git-deploy-logrotate install *, \\
    $LIB_DIR/git-deploy-cron install *
# The web user: deploy.conf runs artisan/composer/pnpm as it. That is code
# execution as $WEB_USER by design (a deploy ships code that $WEB_USER runs
# anyway); it is not root and not a way to become root.
$DEPLOY_USER ALL=($WEB_USER) NOPASSWD: ALL
SUDOERS
  if visudo -cf "$TMP" > /dev/null; then
    install -m 0440 -o root -g root "$TMP" "$SUDOERS_FILE"
    SUDO_STATUS="$SUDOERS_FILE for $DEPLOY_USER"
    rm -f "$TMP"
  else
    rm -f "$TMP"
    echo "install.sh: generated sudoers did not validate; left $SUDOERS_FILE alone" >&2
    exit 1
  fi

  # pm2 keeps one daemon per OS user and starts one on any command, so a bare
  # `pm2 list` as an admin login would spawn a second, empty daemon. Put a wrapper
  # ahead of the real binary that runs pm2 as the deploy user (an alias would not
  # cover `ssh host pm2 ...`). Never replaces a pm2 that is not ours.
  REAL_PM2=""
  IFS=: read -ra PATH_DIRS <<< "$PATH"
  for dir in "${PATH_DIRS[@]}"; do
    [[ "$dir" == "$BIN_DIR" || ! -x "$dir/pm2" ]] && continue
    REAL_PM2="$(readlink -f "$dir/pm2")"
    break
  done
  PM2_STATUS="no pm2 found on PATH, wrapper not installed"
  if [[ -n "$REAL_PM2" ]]; then
    if [[ -e "$BIN_DIR/pm2" ]] && ! grep -q 'managed by git-deploy-toolkit install.sh (pm2 wrapper)' "$BIN_DIR/pm2"; then
      PM2_STATUS="$BIN_DIR/pm2 exists and is not ours, left alone"
    else
      sed "s#@REAL_PM2@#$REAL_PM2#g" "$SRC_DIR/share/pm2-wrapper" > "$BIN_DIR/pm2.new"
      chmod 0755 "$BIN_DIR/pm2.new"
      mv -f "$BIN_DIR/pm2.new" "$BIN_DIR/pm2"
      PM2_STATUS="$BIN_DIR/pm2 runs $REAL_PM2 as $DEPLOY_USER for everyone else"
    fi
  fi
fi

echo "git-deploy-toolkit installed:"
echo "  hook:   $LIB_DIR/post-receive"
echo "  helper: $BIN_DIR/git-deploy-new"
echo "  check:  $BIN_DIR/git-deploy-check (sudo git-deploy-check: read-only health check of the setup)"
echo "  update: $BIN_DIR/git-deploy-update (pulls $SRC_DIR and re-runs this script)"
echo "  releases (optional): git-deploy-rollback, git-deploy-releases-init — see README \"Release directories\"."
echo "    An app's deploy_restart usually needs a php-fpm reload after the swap, e.g."
echo "    <deploy-user> ALL=(root) NOPASSWD: /usr/bin/systemctl reload php*-fpm  (scope it to your unit)"
echo "  webhook (optional): $LIB_DIR/git-deploy-webhook, git-deploy-webhook@.service"
echo "  sudo: $SUDO_STATUS"
echo "  pm2:  $PM2_STATUS"
echo "  root helpers (reached only through that sudoers file): git-deploy-service, git-deploy-fixperms,"
echo "    git-deploy-logrotate (deploy.logrotate), git-deploy-cron (deploy.cron). See docs/deploy-user.md."
if [[ -z "$DEPLOY_USER" ]]; then
  echo "    Without --deploy-user, allow them by hand, e.g. in /etc/sudoers.d/git-deploy-logrotate (mode 0440):"
  echo "    <deploy-user> ALL=(root) NOPASSWD: $LIB_DIR/git-deploy-logrotate install *"
fi
echo
echo "Create a new app with: git-deploy-new <app-name> [worktree-path] [branch]"
