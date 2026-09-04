#!/usr/bin/env bash
# periodic.sh — run a command on an interval, forever, under launchd KeepAlive.
#
# WHY THIS EXISTS
# launchd's `StartInterval` does not work on this machine. Measured 2026-09-04:
# `com.hhouse.runner-guard` (StartInterval 120) logged `runs = 1` and its last cycle
# was 2026-07-25 — six weeks dead. `com.hhouse.ci-janitor` (StartInterval 86400) showed
# the identical signature: `runs = 1`, last cycle 2026-08-18, its install day. A
# controlled A/B probe settled it: a throwaway agent with `StartInterval 10` sat at
# `runs = 0 / pended nondemand spawn` for three minutes without firing once, while an
# identical agent with `KeepAlive` ran continuously and ticked every 10s. launchd in
# this gui/501 domain accepts a bootstrap and honours an explicit `launchctl kickstart`
# (a DEMAND spawn), but never executes the pended NONDEMAND spawns an interval needs.
#
# So the scheduling primitive has to be one that needs exactly ONE successful spawn and
# then persists, instead of one that needs a fresh spawn every cycle (720/day for the
# guard, every one of which silently didn't happen). This script is that primitive: the
# agent becomes a long-lived process that owns its own clock, and launchd is demoted
# from "scheduler we trust" to "supervisor that restarts us if we die" — a job it does
# do. Time stops being ambient and becomes state this script owns. [LAW:no-ambient-temporal-coupling]
#
# The failure that made this necessary was not the dead timer; it was that a dead timer
# LOOKS EXACTLY LIKE a quiet one. So every cycle stamps a heartbeat, unconditionally.
# Liveness becomes a fact on disk with a timestamp anyone can read, rather than an
# assumption. `--status` turns it into an exit code. [LAW:no-silent-failure] [LAW:verifiable-goals]
#
# One supervisor, N supervised jobs: runner-guard and ci-janitor differ only in their
# interval and their command — configuration, i.e. values crossing one boundary — so
# they are two INSTANCES of this one type, not two copies of a loop that would drift.
# [LAW:one-type-per-behavior] [LAW:composability]
#
# EXIT CODES (a contract, per the CLI binding — each code a distinct outcome):
#   0  --status only: the heartbeat is fresh (the supervisor is alive)
#   1  --status only: the heartbeat is STALE or missing (the supervisor is NOT running)
#   2  bad invocation, or the supervised command is missing/not executable — the
#      supervisor cannot run at all. Never confused with "ran and the job failed":
#      a failing job is normal and is recorded IN the heartbeat, not in this exit code.
# In loop mode the script does not exit on its own; it runs until signalled.
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
usage:
  periodic.sh --label L --interval SECS --heartbeat PATH [--timeout SECS] -- COMMAND [ARG...]
  periodic.sh --status --heartbeat PATH --interval SECS

  --label      name used in log lines (e.g. runner-guard)
  --interval   seconds to sleep between cycles
  --heartbeat  file stamped after every cycle; its mtime is the liveness signal
  --timeout    kill one cycle after this many seconds (default: --interval).
               A hung cycle is the one failure KeepAlive cannot see — the process is
               still alive, so launchd is satisfied while nothing is actually running.
  --status     report whether the heartbeat is fresh; exit 0 fresh, 1 stale
USAGE
}

LABEL="" INTERVAL="" HEARTBEAT="" TIMEOUT="" STATUS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --label)     LABEL="${2:-}";     shift 2 ;;
    --interval)  INTERVAL="${2:-}";  shift 2 ;;
    --heartbeat) HEARTBEAT="${2:-}"; shift 2 ;;
    --timeout)   TIMEOUT="${2:-}";   shift 2 ;;
    --status)    STATUS=1;           shift ;;
    --)          shift; break ;;
    *) echo "periodic.sh: unknown argument '$1'" >&2; usage; exit 2 ;;
  esac
done

# Validate every input before the loop, not inside it: a bad interval discovered on
# cycle 500 is a supervisor that looked healthy for a day. Loud, at the boundary, once.
# [LAW:no-silent-failure]
[[ -n "$HEARTBEAT" ]] || { echo "periodic.sh: --heartbeat is required" >&2; usage; exit 2; }
[[ "$INTERVAL" =~ ^[0-9]+$ && "$INTERVAL" -gt 0 ]] \
  || { echo "periodic.sh: --interval must be a positive integer (got '${INTERVAL}')" >&2; exit 2; }

# --- status mode --------------------------------------------------------------
# Freshness bar: a heartbeat older than two intervals plus a minute of slack. One
# interval would false-alarm on any cycle that merely ran long; two plus slack fires
# only when a cycle was genuinely skipped — which, on this machine, means the agent is
# gone. This is the check that would have caught the six-week outage on day one.
if [[ "$STATUS" -eq 1 ]]; then
  max_age=$(( INTERVAL * 2 + 60 ))
  if [[ ! -f "$HEARTBEAT" ]]; then
    echo "STALE: no heartbeat at $HEARTBEAT — the agent has never completed a cycle" >&2
    exit 1
  fi
  now=$(date +%s)
  # stat -f %m is the BSD/macOS spelling; this script is macOS-only by construction
  # (it exists to work around a macOS launchd defect).
  mtime=$(stat -f %m "$HEARTBEAT") || { echo "STALE: cannot stat $HEARTBEAT" >&2; exit 1; }
  age=$(( now - mtime ))
  if [[ "$age" -gt "$max_age" ]]; then
    echo "STALE: heartbeat is ${age}s old (max ${max_age}s) — agent is not running: $(cat "$HEARTBEAT" 2>/dev/null)" >&2
    exit 1
  fi
  echo "fresh: heartbeat ${age}s old (max ${max_age}s) — $(cat "$HEARTBEAT" 2>/dev/null)"
  exit 0
fi

# --- loop mode ----------------------------------------------------------------
[[ -n "$LABEL" ]] || { echo "periodic.sh: --label is required" >&2; usage; exit 2; }
[[ $# -gt 0 ]]    || { echo "periodic.sh: no command given after --" >&2; usage; exit 2; }
TIMEOUT="${TIMEOUT:-$INTERVAL}"
[[ "$TIMEOUT" =~ ^[0-9]+$ && "$TIMEOUT" -gt 0 ]] \
  || { echo "periodic.sh: --timeout must be a positive integer (got '${TIMEOUT}')" >&2; exit 2; }

# The supervised command must exist NOW. Discovering it at cycle time would produce a
# process launchd happily keeps alive while it accomplishes nothing — the exact shape of
# the failure this file exists to end. [LAW:no-silent-failure]
command -v "$1" >/dev/null 2>&1 || [[ -x "$1" ]] \
  || { echo "periodic.sh: supervised command '$1' not found or not executable" >&2; exit 2; }

mkdir -p "$(dirname "$HEARTBEAT")" || true
log() { printf '%s periodic[%s]: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$LABEL" "$*"; }

# Clean shutdown on bootout/kickstart -k. `sleep` in the foreground would swallow the
# signal until it returned (up to a full interval of launchd waiting, then SIGKILL), so
# the sleep runs in the background and we `wait` on it — that IS interruptible.
running_pid=""
killer_pid=""
# Shut down the whole cycle, not just the command. The killer is a forked subshell holding
# its own `sleep`; killing only the command left BOTH of them running, reparented to init,
# every time the agent was stopped or restarted — and because the fork inherits this
# script's command line verbatim, the strays are indistinguishable from the supervisor in
# `ps`, which is a fine way to spend an hour chasing the wrong process. Children before
# parent: `pkill -P` against an already-dead parent matches nothing.
terminate() {
  log "signalled; shutting down"
  if [[ -n "$killer_pid" ]]; then
    pkill -P "$killer_pid" 2>/dev/null || true
    kill "$killer_pid" 2>/dev/null || true
  fi
  if [[ -n "$running_pid" ]]; then
    kill "$running_pid" 2>/dev/null || true
  fi
  exit 0
}
trap terminate TERM INT

log "starting: every ${INTERVAL}s, cycle timeout ${TIMEOUT}s, command: $*"

while true; do
  marker="${HEARTBEAT}.timedout.$$"
  rm -f "$marker"

  "$@" & running_pid=$!
  # The cycle's own deadline, owned explicitly here rather than hoped for. macOS ships
  # no timeout(1), so this is it: a killer that races the command and leaves a marker so
  # a timeout is distinguishable from a command that merely exited 143 on its own.
  # [LAW:no-ambient-temporal-coupling]
  ( sleep "$TIMEOUT"; if kill -0 "$running_pid" 2>/dev/null; then : > "$marker"; kill -TERM "$running_pid" 2>/dev/null; sleep 5; kill -KILL "$running_pid" 2>/dev/null; fi ) & killer=$!
  killer_pid="$killer"

  rc=0; wait "$running_pid" || rc=$?
  running_pid=""
  # Kill the killer's OWN `sleep` before the killer, not just the killer. Killing the
  # subshell leaves the sleep it spawned running, reparented to init — one orphan per
  # cycle, which at a 120s interval and a 900s timeout means a steady handful of stray
  # processes forever. Measured: five live `sleep 900` at ppid 1 after eleven minutes.
  # Children first, because `pkill -P` on an already-dead parent finds nothing and the
  # sleep is orphaned exactly as before. [LAW:no-silent-failure]
  pkill -P "$killer" 2>/dev/null || true
  kill "$killer" 2>/dev/null || true
  wait "$killer" 2>/dev/null || true
  killer_pid=""

  if [[ -f "$marker" ]]; then
    rc="timeout"
    log "cycle exceeded ${TIMEOUT}s and was killed"
  fi
  rm -f "$marker"

  # Stamped every cycle, whatever happened — this asserts "the supervisor is alive",
  # which is a different fact from "the job succeeded". The job's outcome rides along as
  # DATA in the line, so a persistently-failing job never reads as a dead agent and a
  # dead agent never hides behind a succeeding one. [LAW:one-source-of-truth]
  printf '%s %s %s exit=%s\n' "$(date +%s)" "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$LABEL" "$rc" > "${HEARTBEAT}.tmp" \
    && mv -f "${HEARTBEAT}.tmp" "$HEARTBEAT" \
    || log "WARNING: could not write heartbeat $HEARTBEAT"

  sleep "$INTERVAL" & running_pid=$!
  wait "$running_pid" || true
  running_pid=""
done
