#!/usr/bin/env bash
# install-agent.sh — load a periodic.sh-supervised LaunchAgent, and PROVE it is running.
#
# WHY THIS EXISTS, AND WHY IT VERIFIES
# The old per-agent installers ended by printing "installed: com.hhouse.runner-guard" and
# a `launchctl print` command for the human to run. Both agents were duly "installed".
# Both then executed exactly one cycle and stopped — runner-guard for six weeks, while the
# crash-loop it existed to catch ran 3,203 times underneath it. Nothing lied; nobody had
# ever established that "installed" implied "running". So this installer does not report
# success on the strength of `launchctl bootstrap` returning 0. It captures the heartbeat
# before kickstarting and waits for it to ADVANCE — a completed cycle, observed — and
# says so only then. A claim of success is a map; this is the territory.
# [LAW:verifiable-goals] [FRAMING:representation]
#
# Everything it needs is READ FROM THE PLIST — label, supervisor, interval, heartbeat,
# supervised command, PATH. The plist is already the authority launchd obeys; a second
# copy of any of it here is a copy that can drift from the thing actually running.
# [LAW:one-source-of-truth]
#
# runner-guard and ci-janitor are two INSTANCES of one install, differing only in which
# plist and which binaries they need present — so there is one installer taking those as
# values, not two near-identical scripts drifting apart. [LAW:one-type-per-behavior]
#
# EXIT CODES (a contract):
#   0  the agent is loaded AND completed a cycle — proven running
#   1  a precondition failed, or launchd refused to load it — not installed
#   3  loaded, but no cycle completed within the verification window — NOT proven
#      running. Distinct from 0 on purpose: unverified is not the same as working.
set -euo pipefail

PLIST="${1:-}"
shift || true
REQUIRED_BINS=("$@")

[[ -n "$PLIST" ]] || { echo "usage: install-agent.sh <plist> [required-binary...]" >&2; exit 1; }
[[ -r "$PLIST" ]] || { echo "ERROR: plist not readable: $PLIST" >&2; exit 1; }
plutil -lint "$PLIST" >/dev/null || { echo "ERROR: $PLIST is not a valid plist" >&2; exit 1; }

# How long to wait for the first cycle. The guard samples a 20s window and may then
# recreate runners; a janitor sweep enumerates the whole daemon. Generous enough not to
# false-alarm, bounded so the installer always terminates with a verdict.
VERIFY_TIMEOUT="${INSTALL_AGENT_VERIFY_TIMEOUT:-180}"

pget() { plutil -extract "$1" raw -o - "$PLIST" 2>/dev/null; }

LABEL=$(pget Label) || { echo "ERROR: no Label in $PLIST" >&2; exit 1; }
[[ -n "$LABEL" ]]   || { echo "ERROR: empty Label in $PLIST" >&2; exit 1; }

# Walk ProgramArguments by index; plutil fails cleanly past the end.
ARGS=()
i=0
while v=$(pget "ProgramArguments.$i"); do ARGS+=("$v"); i=$((i+1)); done
[[ ${#ARGS[@]} -gt 0 ]] || { echo "ERROR: $PLIST has no ProgramArguments" >&2; exit 1; }

# Pull the supervisor's own flags back out, so the installer verifies the SAME heartbeat
# and interval the agent will actually use rather than a hardcoded guess at them.
INTERVAL="" HEARTBEAT="" SUPERVISOR="" CMD=""
seen_ddash=0
for (( i=0; i<${#ARGS[@]}; i++ )); do
  case "${ARGS[$i]}" in
    --interval)  INTERVAL="${ARGS[$((i+1))]:-}" ;;
    --heartbeat) HEARTBEAT="${ARGS[$((i+1))]:-}" ;;
    --)          seen_ddash=1 ;;
  esac
done
SUPERVISOR="${ARGS[1]:-}"
# The supervised command is written `-- /bin/bash <script>`, so the element straight after
# `--` is the INTERPRETER, not the thing being supervised. Taking that one meant the
# existence check below dutifully confirmed /bin/bash was present — which it always is —
# and reported "runs: /bin/bash", while never checking the script that actually matters.
# A check that cannot fail is not a check. The script is the last argument.
# [LAW:verifiable-goals]
CMD="${ARGS[$(( ${#ARGS[@]} - 1 ))]:-}"

[[ -n "$HEARTBEAT" ]] || { echo "ERROR: $PLIST does not pass --heartbeat to periodic.sh; this installer only handles supervised agents" >&2; exit 1; }
[[ -n "$INTERVAL"  ]] || { echo "ERROR: $PLIST does not pass --interval to periodic.sh" >&2; exit 1; }
[[ "$seen_ddash" -eq 1 ]] || { echo "ERROR: $PLIST has no '--' separating periodic.sh's flags from the supervised command" >&2; exit 1; }

# The agent runs the dotbot-linked runtime paths named in the plist, NOT this checkout.
# Bootstrapping an agent whose scripts are not at those paths is a launchd job that fails
# every cycle — the exact silent failure this whole change exists to end.
# [LAW:no-silent-failure] [LAW:one-source-of-truth]
for f in "$SUPERVISOR" "$CMD"; do
  [[ -e "$f" ]] || {
    echo "ERROR: $f is missing — run './install' from the dotfiles root first so the" >&2
    echo "       ~/.config symlinks exist, then re-run this." >&2
    exit 1
  }
done
# The supervised script is invoked through /bin/bash by the plist, but a non-executable
# file here almost always means a broken link rather than a deliberate choice.
chmod +x "$SUPERVISOR" "$CMD" 2>/dev/null || true

# Check required binaries against the EXACT PATH the agent will run with, read from the
# plist so that PATH has one source. Validating the installer's ambient PATH instead
# would pass while the agent hits 'command not found' (docker resolved via
# /usr/local/bin, a Docker Desktop shim, asdf, …, none on the agent's fixed PATH).
AGENT_PATH=$(pget EnvironmentVariables.PATH) \
  || { echo "ERROR: could not read agent PATH from $PLIST" >&2; exit 1; }
for bin in ${REQUIRED_BINS+"${REQUIRED_BINS[@]}"}; do
  PATH="$AGENT_PATH" command -v "$bin" >/dev/null \
    || { echo "ERROR: '$bin' not found on the agent PATH ($AGENT_PATH) — 'brew install $bin'?" >&2; exit 1; }
done

mkdir -p "$(dirname "$HEARTBEAT")" "$HOME/Library/LaunchAgents"

DEST="$HOME/Library/LaunchAgents/${LABEL}.plist"
ln -sf "$PLIST" "$DEST"   # symlink so repo edits to the plist take effect on reload

# Record the heartbeat we are superseding. Waiting for the file to merely EXIST would be
# satisfied instantly by the corpse of a previous install; waiting for its mtime to move
# is what actually proves a new cycle ran. [LAW:verifiable-goals]
before=0
[[ -f "$HEARTBEAT" ]] && before=$(stat -f %m "$HEARTBEAT" 2>/dev/null || echo 0)

DOMAIN="gui/$(id -u)"
# `launchctl bootout` returns before the job is actually gone, and these agents are now
# long-running processes rather than something that exits in milliseconds — so bootstrap
# raced the teardown and failed with the famously unhelpful "Bootstrap failed: 5:
# Input/output error", which reads like a broken plist and is really just "that label is
# still loaded". Wait for the unload to be OBSERVED instead of assumed: the ordering here
# is a real precondition, so it gets an explicit check rather than a hopeful sleep.
# [LAW:no-ambient-temporal-coupling]
launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true   # ignore "not loaded"
unload_waited=0
while launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; do
  [[ "$unload_waited" -ge 30 ]] && { echo "ERROR: $LABEL is still loaded 30s after bootout; not replacing it blind" >&2; exit 1; }
  sleep 2; unload_waited=$((unload_waited+2))
done
launchctl bootstrap "$DOMAIN" "$DEST" || { echo "ERROR: launchctl bootstrap failed for $LABEL" >&2; exit 1; }
launchctl enable    "$DOMAIN/$LABEL"
# An explicit kickstart is a DEMAND spawn. On this machine that is the reliable one —
# the nondemand spawns RunAtLoad and StartInterval schedule are exactly what does not
# fire here — so the agent is started deliberately rather than waited for.
launchctl kickstart "$DOMAIN/$LABEL" >/dev/null || { echo "ERROR: launchctl kickstart failed for $LABEL" >&2; exit 1; }

printf 'waiting up to %ss for %s to complete its first cycle' "$VERIFY_TIMEOUT" "$LABEL"
waited=0
while [[ "$waited" -lt "$VERIFY_TIMEOUT" ]]; do
  sleep 5; waited=$((waited+5)); printf '.'
  now=0; [[ -f "$HEARTBEAT" ]] && now=$(stat -f %m "$HEARTBEAT" 2>/dev/null || echo 0)
  if [[ "$now" -gt "$before" ]]; then
    echo
    echo "VERIFIED: $LABEL is running — heartbeat advanced after ${waited}s"
    echo "  $(cat "$HEARTBEAT")"
    echo "  plist:     $DEST -> $PLIST"
    echo "  runs:      $CMD (every ${INTERVAL}s)"
    echo "  heartbeat: $HEARTBEAT"
    echo "  liveness:  $SUPERVISOR --status --interval $INTERVAL --heartbeat $HEARTBEAT"
    exit 0
  fi
done

echo
echo "NOT VERIFIED: $LABEL loaded, but no cycle completed within ${VERIFY_TIMEOUT}s." >&2
echo "  This is not a success. Check, in order:" >&2
echo "    launchctl print $DOMAIN/$LABEL | grep -E 'state|pid|last exit'" >&2
echo "    tail -20 $(dirname "$HEARTBEAT")/launchd.err" >&2
exit 3
