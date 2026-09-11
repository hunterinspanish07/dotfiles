#!/usr/bin/env bash
# install.sh — load ci-janitor as a daily launchd agent. Idempotent.
#
# dotbot owns the ~ symlinks (config/ci-janitor -> ~/.config/ci-janitor); this script owns
# only the launchctl lifecycle, which dotbot can't do. Run `./install` from the dotfiles
# root first so the links exist, then run this.
# Uninstall: launchctl bootout gui/$(id -u)/com.hhouse.ci-janitor
#
# The work is in ~/.config/periodic/install-agent.sh, shared with runner-guard — see the
# note there. It verifies the agent actually completed a sweep before calling the install
# a success; this agent's previous install reported success and then never swept again.
#
# Rehearse a sweep without deleting anything: ~/.config/ci-janitor/ci-janitor.sh --dry-run
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="$HOME/.config/periodic/install-agent.sh"
[[ -x "$INSTALLER" ]] || {
  echo "ERROR: $INSTALLER missing — run './install' from the dotfiles root first so the" >&2
  echo "       ~/.config/periodic symlink exists, then re-run this." >&2
  exit 1
}
exec "$INSTALLER" "$DIR/com.hhouse.ci-janitor.plist" docker colima
