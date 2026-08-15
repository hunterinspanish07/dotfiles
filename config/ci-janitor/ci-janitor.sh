#!/usr/bin/env bash
# ci-janitor.sh — reclaim the disk that self-hosted CI leaks on this machine.
#
# Machine-wide infra, sibling to runner-guard (same host, same shared Colima VM, same
# loud-failure contract). runner-guard answers "is a runner crash-looping?"; this
# answers "is CI garbage filling the disk?" — two purposes, two scripts.
# [LAW:decomposition]
#
# WHY THIS EXISTS
# Ephemeral GitHub Actions runners are ephemeral only in the runner container. Each
# runner mounts the HOST Docker socket, so every service container a job starts — and
# every anonymous volume and per-job network that comes with it — is created on the
# Colima VM's daemon, OUTSIDE the runner's lifecycle. The runner exits; its garbage
# does not. `cancel-in-progress: true` (set on every workflow) makes this routine
# rather than rare: GitHub kills the runner mid-job, the job's own cleanup step never
# executes, and the orphans are simply left behind.
#
# Nothing ever swept them. Measured 2026-08-15: 148 orphaned anonymous volumes
# (11.1 GB) dating back to 2026-06-23, plus 13.8 GB of untagged images — on a 98 GB
# disk that had reached 70%. It surfaced as a CI failure with no obvious link to its
# cause: "tar: ./md5sums: Cannot open: No space left on device" during a Playwright
# Chromium install. Two months of silent accumulation, one confusing red X.
#
# THE SAFETY MODEL: AN ALLOWLIST, NOT A BLOCKLIST
# This machine also runs things that must never be touched — a Supabase stack used for
# local Grounded development, ChromaDB, actualbudget, buildx builders, and three CI
# runner containers. So the illegal state ("the janitor deleted something in use") is
# made unrepresentable rather than guarded against: every sweep matches a POSITIVE
# signature that only CI garbage can structurally have, and anything unrecognized is
# kept. A blocklist ("delete all but these") fails OPEN — whatever gets installed next
# year and isn't on the list gets deleted. An allowlist fails CLOSED.
# [LAW:types-are-the-program]
#
# This is not hypothetical. `docker volume prune` reports the real, in-use volume
# `supabase_edge_runtime_grounded` as dangling; a blanket prune would delete it. The
# 64-hex-name rule below cannot match it, because Docker only assigns 64-hex names to
# ANONYMOUS volumes — the exact kind a CI service container creates. The safety is
# structural, not a name this script has to remember to exclude.
#
# The three sweeps, and why each is safe:
#   1. Anonymous volumes  — name is exactly 64 hex chars AND dangling AND aged.
#                           No named volume can match; Docker won't name one that way.
#   2. Untagged images    — <none>:<none> AND aged. Tagged images are never touched,
#                           so no `supabase start` ever re-pulls a pinned version.
#   3. Actions networks   — name matches github_network_<hex>, a namespace only the
#      + their containers   Actions runner creates, AND aged. This is what removes an
#                           orphaned Postgres still squatting a port; it also releases
#                           the anonymous volume it pins, which sweep 1 then reclaims.
#
# Deliberately NOT swept, because the risk outweighs the space: tagged-but-unused
# images (deleting them forces multi-GB re-pulls of Supabase versions Grounded pins),
# stopped containers in general (the runner containers run `--restart=always` and sit
# EXITED between jobs — removing one during that window permanently kills that repo's
# CI), build cache (208 MB, and shared with the buildx builders), and /runner-work
# (2.2 GB, but an actively-used repo's checkout never ages out anyway).
#
# HOW "DON'T TOUCH A LIVE JOB" IS GUARANTEED
# Not by polling for running jobs, and not by a settle-sleep — both are races. The age
# floor IS the guarantee: jobs on this host take 1-2 minutes and the platform's own
# ceiling is 6 hours, so at the 24h default nothing this script can see could belong to
# a job still running. The temporal invariant is a property of the data, not a hope
# about timing. [LAW:no-ambient-temporal-coupling]
#
# HOW YOU FIND OUT IT BROKE
# The whole point of this script is that silent accumulation is what hurt. So it is
# built to be loud about its own failure: every non-zero exit both logs and raises a
# desktop notification, and two independent checks catch the failure modes that a
# sweep-only janitor would miss —
#   * the post-sweep high-water check fires when the disk is STILL above threshold
#     after a clean sweep, which is how you learn something is accumulating from a
#     source these three sweeps don't cover;
#   * the staleness check fires when the janitor itself hasn't run, which is how you
#     learn the launchd agent died rather than assuming silence meant health.
# A successful run stays quiet in the notification channel (it always logs) — daily
# "cleaned up fine" alerts train you to ignore the channel that carries the alarms.
# [LAW:no-silent-failure]
#
# EXIT CODES (a contract, per the CLI binding — each a distinct, actionable outcome):
#   0  ran clean — swept what was there (or there was nothing), disk healthy
#   2  the janitor could not run at all (Docker/Colima unreachable) — NOT "all clean"
#   3  a removal failed, or an age could not be determined, so the sweep is incomplete
#   4  swept clean, but the disk is STILL above the high-water mark — something is
#      accumulating that these sweeps do not cover; investigate by hand
#   5  the janitor had not run for far longer than its schedule — it was silently dead
set -euo pipefail

# --- configuration ------------------------------------------------------------
# Nothing younger than this is ever touched, in any sweep. See "HOW 'DON'T TOUCH A
# LIVE JOB' IS GUARANTEED" above — this single number is that guarantee, so it has one
# home and every sweep reads it. [LAW:one-source-of-truth]
AGE_HOURS="${CI_JANITOR_AGE_HOURS:-24}"
# Percent-used of the Docker disk above which a post-sweep run is considered a failure
# to keep up, not a success. 85 leaves real headroom on the 98 GB volume: the Playwright
# install that first exposed this needs a few GB of scratch.
DISK_WARN_PCT="${CI_JANITOR_DISK_WARN_PCT:-85}"
# Flag the janitor's own silence. The agent runs daily; 72h means two consecutive
# missed days, past any plausible "the laptop was closed over a weekend".
STALE_HOURS="${CI_JANITOR_STALE_HOURS:-72}"
LOG_FILE="${CI_JANITOR_LOG:-$HOME/.local/share/ci-janitor/janitor.log}"
STATE_FILE="${CI_JANITOR_STATE:-$HOME/.local/share/ci-janitor/last-run}"
# The Docker disk inside the Colima VM. `docker system df` reports what Docker owns but
# never how much room is LEFT, and free space is the quantity that actually causes
# ENOSPC — so the high-water check has to ask the VM's filesystem directly.
DOCKER_DISK="${CI_JANITOR_DOCKER_DISK:-/var/lib/docker}"

# Read-only mode: classify and report every candidate exactly as a real run would, and
# hold the deletions. Same exit codes, so a dry run is a truthful rehearsal.
# [LAW:effects-at-boundaries]
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; exit 64 ;;
  esac
done

mkdir -p "$(dirname "$LOG_FILE")"

# `|| true` on the tee only: a logging effect that fails (unwritable log, full disk —
# both plausible for THIS script in particular) must never abort the run under errexit
# and skip the sweep that would have fixed it. The isolation is the log's, not the
# caller's. [LAW:effects-at-boundaries]
log()  { printf '%s ci-janitor: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE" || true; }
warn() { printf '%s ci-janitor: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE" >&2 || true; }
notify() {
  osascript -e "display notification \"${1//\"/\'}\" with title \"CI janitor\"" >/dev/null 2>&1 \
    || warn "note: desktop notification failed (osascript); the alert is in $LOG_FILE"
}
# Docker being unreachable is the janitor failing, not the disk being clean. Reporting
# success here is the silent-fallback trap this script exists to prevent. [LAW:no-silent-failure]
die() { warn "FATAL: $*"; notify "CI janitor COULD NOT RUN — $1. See ${LOG_FILE}."; exit 2; }

incomplete=0   # something could not be removed or could not be aged — sweep is partial
reclaimed=0    # count of objects actually removed (or that a dry run would remove)

# --- helpers ------------------------------------------------------------------
# Docker stamps three shapes: '2026-07-14T08:22:33-05:00' (volumes),
# '2026-08-04 19:39:08 -0500 CDT' (images), and the same with nanoseconds (networks).
# All three share a 19-char 'YYYY-MM-DD?HH:MM:SS' prefix in LOCAL time, which is
# exactly what BSD `date -j` parses. Normalising to that prefix reads all three with
# one rule rather than three parsers. [LAW:one-type-per-behavior]
epoch_of() {
  local ts="${1:0:19}"
  date -j -f '%Y-%m-%d %H:%M:%S' "${ts/T/ }" +%s 2>/dev/null
}

NOW=$(date +%s)
CUTOFF=$(( NOW - AGE_HOURS * 3600 ))

# True only when the object is provably older than the floor. An unparseable timestamp
# returns FALSE — the object is kept and the run is marked incomplete. Failing closed is
# the whole safety model: never delete something whose age you could not establish.
# [LAW:no-silent-failure]
is_old_enough() {
  local created="$1" what="$2" epoch
  epoch=$(epoch_of "$created") || {
    warn "skip: could not parse timestamp '$created' for $what; keeping it (run is incomplete)"
    incomplete=1
    return 1
  }
  [[ -n "$epoch" ]] || {
    warn "skip: empty timestamp for $what; keeping it (run is incomplete)"
    incomplete=1
    return 1
  }
  [[ "$epoch" -lt "$CUTOFF" ]]
}

# grep's exit 1 means "nothing matched" — a legitimate empty result, not an error.
# Exit 2+ IS an error and must not be laundered into an empty list, which would read as
# "no garbage found" and quietly stop the janitor doing its job. [LAW:no-silent-failure]
#
# So this reports a real grep error the ordinary way — as its OWN exit status — and every
# caller must pair it with `|| die`. It deliberately does NOT call `die` itself: callers
# invoke it as `v=$(match_or_empty ...)`, and inside that command substitution `exit`
# would only end the subshell. Today errexit still catches that (bash gives a bare
# `var=$(...)` assignment the substitution's status), so the failure is loud by a narrow
# interpreter rule rather than by design — and one refactor to `local v=$(...)` would
# silently break it, because `local`'s own exit 0 masks the substitution's status. The
# status-plus-`|| die` contract is visible at the call site and survives that edit.
match_or_empty() {
  local pattern="$1" input="$2" out rc
  out=$(printf '%s\n' "$input" | grep -E "$pattern") || {
    rc=$?
    [[ "$rc" -eq 1 ]] || return "$rc"
    out=""
  }
  printf '%s' "$out"
}

# The single place a deletion happens, so dry-run is one branch in one function rather
# than a conditional threaded through every sweep. [LAW:effects-at-boundaries]
remove_one() {
  local what="$1" label="$2"; shift 2
  if [[ "$DRY_RUN" -ne 0 ]]; then
    log "WOULD REMOVE ${what}: ${label}"
    reclaimed=$(( reclaimed + 1 ))
    return 0
  fi
  local err
  if err=$("$@" 2>&1); then
    log "removed ${what}: ${label}"
    reclaimed=$(( reclaimed + 1 ))
    return 0
  fi
  # An image still referenced by a container is a correct outcome, not a fault: report
  # it plainly and do not inflate it into a failed sweep.
  case "$err" in
    *"is being used"*|*"in use"*)
      log "kept ${what}: ${label} — still in use" ;;
    *)
      warn "FAILED to remove ${what} ${label}: ${err}"
      incomplete=1 ;;
  esac
  return 0
}

# --- preflight ----------------------------------------------------------------
docker info >/dev/null 2>&1 || die "Docker daemon unreachable (is Colima up? 'colima start')"

# Did the janitor itself stop running? Only detectable once it runs again after a gap,
# but that is precisely the case worth catching: an agent silently unloaded for weeks
# while the disk refilled. [LAW:no-silent-failure]
was_stale=0
if [[ -f "$STATE_FILE" ]]; then
  last=$(cat "$STATE_FILE") || last=""
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    gap_h=$(( (NOW - last) / 3600 ))
    if [[ "$gap_h" -gt "$STALE_HOURS" ]]; then
      was_stale=1
      warn "STALE: last successful run was ${gap_h}h ago (threshold ${STALE_HOURS}h) — the agent was not running. Check: launchctl print gui/\$(id -u)/com.hhouse.ci-janitor"
    fi
  else
    warn "state file $STATE_FILE is unreadable or malformed; cannot tell when the janitor last ran"
    incomplete=1
  fi
fi

mode_note=""
[[ "$DRY_RUN" -ne 0 ]] && mode_note=" [DRY RUN — nothing will be deleted]"
log "start${mode_note}: age floor ${AGE_HOURS}h, disk high-water ${DISK_WARN_PCT}%"

# --- sweep 1: anonymous volumes orphaned by CI service containers -------------
# Dangling + a 64-hex name. Docker assigns 64-hex names only to ANONYMOUS volumes, so
# every named volume on this host (supabase_*, actual-data, odysseus_chromadb-data,
# buildx_*_state) is excluded by the shape of its name and not by a list this script
# would have to keep in sync with the machine. [LAW:types-are-the-program]
vols_all=$(docker volume ls --filter dangling=true --format '{{.Name}}') \
  || die "docker volume ls failed"
vols=$(match_or_empty '^[0-9a-f]{64}$' "$vols_all") \
  || die "grep failed (rc=$?) filtering volume names — cannot tell garbage from live data"
if [[ -n "$vols" ]]; then
  while read -r v; do
    [[ -z "$v" ]] && continue
    created=$(docker volume inspect "$v" --format '{{.CreatedAt}}' 2>/dev/null) || {
      warn "skip: could not inspect volume $v; keeping it (run is incomplete)"
      incomplete=1
      continue
    }
    is_old_enough "$created" "volume $v" || continue
    remove_one "volume" "$v (created ${created:0:10})" docker volume rm "$v"
  done <<< "$vols"
fi

# --- sweep 2: untagged images -------------------------------------------------
# <none>:<none> only. Every tagged image survives, so nothing Grounded or Odyssey pins
# is ever re-pulled because of this script.
imgs=$(docker images --filter dangling=true --format '{{.ID}}|{{.CreatedAt}}') \
  || die "docker images failed"
if [[ -n "$imgs" ]]; then
  while IFS='|' read -r id created; do
    [[ -z "$id" ]] && continue
    is_old_enough "$created" "image $id" || continue
    remove_one "image" "$id (created ${created:0:10})" docker rmi "$id"
  done <<< "$imgs"
fi

# --- sweep 3: orphaned Actions networks, and the containers still on them ------
# `github_network_<hex>` is a namespace only the Actions runner creates, one per job.
# A leftover one means a job died without cleaning up. Containers attached to it are
# that job's service containers — the Postgres that squats a port and pins the
# anonymous volume sweep 1 wants. They are removed first so the network can go, and so
# the next run's sweep 1 can reclaim the volume they were holding.
nets_all=$(docker network ls --format '{{.Name}}') || die "docker network ls failed"
nets=$(match_or_empty '^github_network_[0-9a-f]+$' "$nets_all") \
  || die "grep failed (rc=$?) filtering network names — cannot tell Actions nets from yours"
if [[ -n "$nets" ]]; then
  while read -r n; do
    [[ -z "$n" ]] && continue
    created=$(docker network inspect "$n" --format '{{.Created}}' 2>/dev/null) || {
      warn "skip: could not inspect network $n; keeping it (run is incomplete)"
      incomplete=1
      continue
    }
    is_old_enough "$created" "network $n" || continue
    members=$(docker network inspect "$n" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null) || members=""
    for c in $members; do
      remove_one "orphaned job container" "$c (on $n)" docker rm -f "$c"
    done
    remove_one "network" "$n (created ${created:0:10})" docker network rm "$n"
  done <<< "$nets"
fi

# --- post-sweep high-water check ----------------------------------------------
# The backstop that makes the rest honest. The sweeps only reclaim what they recognise;
# this asks the filesystem whether that was actually ENOUGH. A janitor that reports
# success while the disk fills from a source it does not cover is the same silent lie,
# one level up. [LAW:no-silent-failure] [LAW:verifiable-goals]
disk_pct=""
if df_out=$(colima ssh -- df -P "$DOCKER_DISK" 2>/dev/null); then
  disk_pct=$(printf '%s\n' "$df_out" | awk 'NR==2 {gsub(/%/,"",$5); print $5}')
fi
if [[ ! "$disk_pct" =~ ^[0-9]+$ ]]; then
  # Never treat an unmeasurable disk as a healthy one.
  warn "could not read usage of $DOCKER_DISK via colima; the high-water check did not run this cycle"
  incomplete=1
  disk_pct=""
else
  log "docker disk ${DOCKER_DISK} is ${disk_pct}% used (high-water ${DISK_WARN_PCT}%)"
fi

# Record the run only when it actually completed, so the staleness check measures
# successful runs rather than mere invocations. A dry run is a rehearsal and must not
# reset the clock. [LAW:one-source-of-truth]
if [[ "$DRY_RUN" -eq 0 && "$incomplete" -eq 0 ]]; then
  printf '%s' "$NOW" > "$STATE_FILE" || warn "note: could not write state file $STATE_FILE"
fi

# --- outcome ------------------------------------------------------------------
# Precedence, most-severe first; each code is a different thing for you to do.
# [LAW:types-are-the-program]
log "done${mode_note}: ${reclaimed} object(s) $([[ "$DRY_RUN" -ne 0 ]] && echo 'would be removed' || echo 'removed')"

if [[ "$incomplete" -ne 0 ]]; then
  warn "INCOMPLETE: at least one object could not be removed or aged — garbage may still be accumulating"
  notify "CI janitor INCOMPLETE — something could not be swept; disk may still be filling. See ${LOG_FILE}."
  exit 3
fi
if [[ -n "$disk_pct" && "$disk_pct" -ge "$DISK_WARN_PCT" ]]; then
  warn "HIGH WATER: ${DOCKER_DISK} still ${disk_pct}% used after a clean sweep — something is accumulating that these sweeps do not cover. Inspect with: docker system df -v"
  notify "CI janitor: disk still ${disk_pct}% after cleaning — something else is filling it. See ${LOG_FILE}."
  exit 4
fi
if [[ "$was_stale" -ne 0 ]]; then
  notify "CI janitor had NOT run in over ${STALE_HOURS}h — the agent was down. It ran now; check the schedule."
  exit 5
fi
exit 0
