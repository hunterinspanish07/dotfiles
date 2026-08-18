#!/usr/bin/env bash
# install.sh — load ci-janitor as a daily launchd agent. Idempotent.
#
# dotbot owns the ~ symlinks (config/ci-janitor -> ~/.config/ci-janitor); this script
# owns only the launchctl lifecycle, which dotbot can't do. Run `./install` from the
# dotfiles root first so the link exists, then run this.
# Uninstall: launchctl bootout gui/$(id -u)/com.hhouse.ci-janitor
set -euo pipefail

LABEL="com.hhouse.ci-janitor"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLIST_SRC="$DIR/${LABEL}.plist"

# The agent runs the dotbot-linked path (what the plist's ProgramArguments names), NOT
# this checkout — bootstrapping an agent whose script isn't there would be a launchd job
# that silently fails every cycle, which is the exact failure this tool exists to end.
# [LAW:no-silent-failure] [LAW:one-source-of-truth]
RUNTIME_SCRIPT="$HOME/.config/ci-janitor/ci-janitor.sh"
[[ -e "$RUNTIME_SCRIPT" ]] || {
  echo "ERROR: $RUNTIME_SCRIPT missing — run './install' from the dotfiles root first so" >&2
  echo "       the ~/.config/ci-janitor symlink exists, then re-run this." >&2
  exit 1
}
# Check the binaries against the EXACT PATH the agent will run with, read from the
# plist so that PATH has ONE source rather than a second copy here that can drift.
# Validating this installer's ambient PATH instead would pass while the agent hits
# 'command not found' (docker resolved via /usr/local/bin, a Docker Desktop shim, asdf,
# …, none of which are on the agent's fixed PATH). [LAW:one-source-of-truth]
AGENT_PATH=$(plutil -extract EnvironmentVariables.PATH raw -o - "$PLIST_SRC") \
  || { echo "ERROR: could not read agent PATH from $PLIST_SRC" >&2; exit 1; }
# Both are load-bearing: docker for the sweeps, colima for the high-water disk check
# (Docker reports what it owns, never how much room is left). A missing colima would
# demote every run to exit 3 rather than failing here where it is fixable.
for bin in docker colima; do
  PATH="$AGENT_PATH" command -v "$bin" >/dev/null \
    || { echo "ERROR: '$bin' not found on the agent PATH ($AGENT_PATH) — 'brew install $bin'?" >&2; exit 1; }
done
chmod +x "$RUNTIME_SCRIPT"
mkdir -p "$HOME/.local/share/ci-janitor" "$HOME/Library/LaunchAgents"

DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
ln -sf "$PLIST_SRC" "$DEST"   # symlink so repo edits to the plist take effect on reload

DOMAIN="gui/$(id -u)"
launchctl bootout   "$DOMAIN/$LABEL" 2>/dev/null || true   # ignore "not loaded"
launchctl bootstrap "$DOMAIN" "$DEST"
launchctl enable    "$DOMAIN/$LABEL"
launchctl kickstart "$DOMAIN/$LABEL"   # sweep once now, don't wait a day

echo "installed: $LABEL (RunAtLoad + daily)"
echo "  plist: $DEST -> $PLIST_SRC"
echo "  runs:  $RUNTIME_SCRIPT"
echo "  log:   $HOME/.local/share/ci-janitor/janitor.log"
echo "verify: launchctl print $DOMAIN/$LABEL | grep -iE 'state|program|runatload'"
echo "rehearse without deleting: $RUNTIME_SCRIPT --dry-run"
