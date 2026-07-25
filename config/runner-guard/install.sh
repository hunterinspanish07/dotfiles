#!/usr/bin/env bash
# install.sh — load runner-guard as an always-on launchd agent. Idempotent.
#
# dotbot owns the ~ symlinks (config/runner-guard -> ~/.config/runner-guard); this
# script owns only the launchctl lifecycle, which dotbot can't do. Run `./install`
# from the dotfiles root first so the link exists, then run this.
# Uninstall: launchctl bootout gui/$(id -u)/com.hhouse.runner-guard
set -euo pipefail

LABEL="com.hhouse.runner-guard"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_SRC="$DIR/${LABEL}.plist"

# The agent runs the dotbot-linked path (what the plist's ProgramArguments names), NOT
# this checkout — bootstrapping an agent whose script isn't there would be a launchd
# job that silently fails every cycle. Verify the link exists; fail loud if not.
# [LAW:no-silent-failure] [LAW:one-source-of-truth]
RUNTIME_GUARD="$HOME/.config/runner-guard/runner-guard.sh"
[[ -e "$RUNTIME_GUARD" ]] || {
  echo "ERROR: $RUNTIME_GUARD missing — run './install' from the dotfiles root first so" >&2
  echo "       the ~/.config/runner-guard symlink exists, then re-run this." >&2
  exit 1
}
command -v docker >/dev/null || { echo "ERROR: docker not on PATH (brew install docker)" >&2; exit 1; }
chmod +x "$RUNTIME_GUARD"
mkdir -p "$HOME/.local/share/runner-guard" "$HOME/Library/LaunchAgents"

DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
ln -sf "$PLIST_SRC" "$DEST"   # symlink so repo edits to the plist take effect on reload

DOMAIN="gui/$(id -u)"
launchctl bootout   "$DOMAIN/$LABEL" 2>/dev/null || true   # ignore "not loaded"
launchctl bootstrap "$DOMAIN" "$DEST"
launchctl enable    "$DOMAIN/$LABEL"
launchctl kickstart "$DOMAIN/$LABEL"   # run one cycle now, don't wait for the interval

echo "installed: $LABEL (RunAtLoad + every 120s)"
echo "  plist: $DEST -> $PLIST_SRC"
echo "  runs:  $RUNTIME_GUARD"
echo "  log:   $HOME/.local/share/runner-guard/guard.log"
echo "verify: launchctl print $DOMAIN/$LABEL | grep -iE 'state|program|runatload'"
