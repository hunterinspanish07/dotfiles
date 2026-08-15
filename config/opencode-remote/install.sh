#!/usr/bin/env bash
# install.sh — load opencode-remote as an always-on launchd agent. Idempotent.
#
# dotbot owns the ~ symlinks; this script owns only the launchctl lifecycle.
# Prefer `ocremote install` — it calls this after verifying the links exist.
# Uninstall: ocremote uninstall
set -euo pipefail

LABEL="com.hhouse.opencode-remote"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_SRC="$DIR/${LABEL}.plist"

# Agent runs the dotbot-linked path, not this checkout. [LAW:no-silent-failure]
# [LAW:one-source-of-truth]
RUNTIME="$HOME/.config/opencode-remote/remote-launch.sh"
[[ -e "$RUNTIME" ]] || {
  echo "ERROR: $RUNTIME missing — run './install' from the dotfiles root first so" >&2
  echo "       the ~/.config/opencode-remote symlink exists, then re-run this." >&2
  exit 1
}
[[ -f "$PLIST_SRC" ]] || {
  echo "ERROR: plist missing: $PLIST_SRC" >&2
  exit 1
}

# Validate binaries against the EXACT PATH the agent will use. [LAW:one-source-of-truth]
AGENT_PATH=$(plutil -extract EnvironmentVariables.PATH raw -o - "$PLIST_SRC") \
  || { echo "ERROR: could not read agent PATH from $PLIST_SRC" >&2; exit 1; }
for bin in opencode opencode-telegram curl; do
  PATH="$AGENT_PATH" command -v "$bin" >/dev/null \
    || { echo "ERROR: $bin not found on the agent PATH ($AGENT_PATH)" >&2; exit 1; }
done

ENV_FILE="$HOME/Library/Application Support/opencode-telegram-bot/.env"
[[ -f "$ENV_FILE" ]] || {
  echo "ERROR: bot config missing: $ENV_FILE" >&2
  echo "       run: opencode-telegram config" >&2
  exit 1
}

chmod +x "$RUNTIME"
mkdir -p \
  "$HOME/Library/LaunchAgents" \
  "$HOME/Library/Application Support/opencode-telegram-bot/logs"

DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
# Symlink so repo edits to the plist take effect on reload. [LAW:one-source-of-truth]
ln -sf "$PLIST_SRC" "$DEST"

DOMAIN="gui/$(id -u)"
# bootout may fail if not loaded — that is fine. Only swallow that case.
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
launchctl bootstrap "$DOMAIN" "$DEST"
launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "installed: $LABEL (RunAtLoad + KeepAlive)"
echo "  plist: $DEST -> $PLIST_SRC"
echo "  runs:  $RUNTIME"
echo "  logs:  $HOME/Library/Application Support/opencode-telegram-bot/logs/"
echo "manage:  ocremote status | start | stop | logs"
