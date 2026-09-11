#!/usr/bin/env bash
# install.sh — load runner-guard as an always-on launchd agent. Idempotent.
#
# dotbot owns the ~ symlinks (config/runner-guard -> ~/.config/runner-guard); this script
# owns only the launchctl lifecycle, which dotbot can't do. Run `./install` from the
# dotfiles root first so the links exist, then run this.
# Uninstall: launchctl bootout gui/$(id -u)/com.hhouse.runner-guard
#
# The work is in ~/.config/periodic/install-agent.sh, shared with ci-janitor: both agents
# are the same install differing only in which plist and which binaries they need, so the
# procedure lives in one place and this file supplies the two values.
# [LAW:one-type-per-behavior]
#
# That installer reads the label, supervisor, interval, heartbeat and PATH out of the
# plist, and — the part that matters — refuses to report success until the heartbeat has
# actually advanced. "installed" now implies "observed running", which is precisely what
# it did not imply the last time this agent was installed and then sat dead for six weeks.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HOME/.config/periodic/install-agent.sh"
[[ -x "$INSTALLER" ]] || {
  echo "ERROR: $INSTALLER missing — run './install' from the dotfiles root first so the" >&2
  echo "       ~/.config/periodic symlink exists, then re-run this." >&2
  exit 1
}
exec "$INSTALLER" "$DIR/com.hhouse.runner-guard.plist" docker
