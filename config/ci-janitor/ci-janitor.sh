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
# The three sweeps (dependency order — containers before the volumes they pin), and
# why each is safe:
#   1. Actions networks   — name matches github_network_<hex>, a namespace only the
#      + their containers   Actions runner creates, AND aged. Removes an orphaned
#                           Postgres still squatting a port; releases the anonymous
#                           volume it pins so the volume sweep can see it as dangling.
#   2. Anonymous volumes  — name is exactly 64 hex chars AND dangling AND aged.
#                           No named volume can match; Docker won't name one that way.
#   3. Untagged images    — <none>:<none> AND aged. Tagged images are never touched,
#                           so no `supabase start` ever re-pulls a pinned version.
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
# a job still running. Age is computed entirely in the Docker daemon's clock domain
# (SystemTime and CreatedAt share one clock) so Mac-vs-VM drift cannot push a live job
# under the floor. [LAW:no-ambient-temporal-coupling]
#
# HOW YOU FIND OUT IT BROKE
# The whole point of this script is that silent accumulation is what hurt. So it is
# built to be loud about its own failure: every non-zero exit from a RUN both logs and
# raises a desktop notification, and two independent checks catch the failure modes that
# a sweep-only janitor would miss —
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
#   3  the run did not fully succeed — a removal/age failed, the staleness clock could
#      not be armed, OR the high-water check could not measure the disk (notify names which)
#   4  swept clean, but the disk is STILL above the high-water mark — something is
#      accumulating that these sweeps do not cover; investigate by hand
#   5  the janitor had not run for far longer than its schedule — it was silently dead
#      (the stale shout also fires on exit 4 when both apply; see outcome block)
#  64  usage error (unrecognized argument), per sysexits EX_USAGE. Deliberately the one
#      non-zero exit that does NOT notify: it is reachable only by typing the command
#      wrong at a terminal, where the stderr line is already in front of you. A desktop
#      alert for a typo is noise in the channel the alarms above have to travel down.
# README.md mirrors this table for human readers; change both together.
# [LAW:one-source-of-truth]
set -euo pipefail

# --- configuration ------------------------------------------------------------
# Nothing younger than this is ever touched, in any sweep. See "HOW 'DON'T TOUCH A
# LIVE JOB' IS GUARANTEED" above — this single number is that guarantee, so it has one
# home and every sweep reads it. [LAW:one-source-of-truth]
#
# AGE_HOURS_MIN is the live-job safety floor made unrepresentable-to-violate: the
# platform's own job ceiling is 6h, so anything below 7h would make sweep 1's
# `docker rm -f` eligible to kill service containers still attached to an in-progress
# job. Validated (not clamped) after `die` exists — a misconfigured floor refuses to
# run rather than executing a destructive sweep under a false safety invariant.
# [LAW:types-are-the-program] [LAW:no-silent-failure]
AGE_HOURS_MIN=7
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
# hold the deletions. Preserves exit 2 (can't run) and exit 3 from classification /
# inspect failures. Deliberately does NOT raise exit 4/5, arm the stamp, or shout
# stale recovery — those are real-run outcomes tied to effects dry-run holds back.
# [LAW:effects-at-boundaries]
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    *) printf 'usage: %s [--dry-run]\n' "${0##*/}" >&2; exit 64 ;;
  esac
done

# The reporting channel is defined BEFORE anything that can fail, so there is no window
# in which the script can die without a voice. `printf | tee` also means every message
# reaches stdout (launchd.out) whether or not the log file itself is writable.
#
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

# Losing the log directory means going blind, so it cannot be the one failure that passes
# unannounced. Unguarded under errexit this exits with only bash's own terse stderr line,
# which on the launchd path lands in launchd.err and nowhere a person looks. Reported
# through notify() instead — which needs no log file at all — and pointing at the
# directory rather than at the log it could not create. [LAW:no-silent-failure]
mkdir -p "$(dirname "$LOG_FILE")" || {
  warn "FATAL: cannot create log directory $(dirname "$LOG_FILE") — refusing to run blind"
  notify "CI janitor COULD NOT RUN — its log directory $(dirname "$LOG_FILE") is not creatable."
  exit 2
}

# Config that would break a safety/monitoring invariant is refused here, not clamped:
# a silent raise-to-floor would lie about what ran; a silent proceed would disable an
# alarm or kill live job containers. Fail loud; fix the env. [LAW:no-silent-failure]
# [LAW:types-are-the-program]
[[ "$AGE_HOURS" =~ ^[1-9][0-9]*$ ]] \
  || die "CI_JANITOR_AGE_HOURS must be a positive integer (got '$AGE_HOURS')"
[[ "$AGE_HOURS" -ge "$AGE_HOURS_MIN" ]] \
  || die "CI_JANITOR_AGE_HOURS=$AGE_HOURS is below the live-job safety floor of ${AGE_HOURS_MIN}h (platform job ceiling is 6h) — refuse to run a destructive sweep under a false safety invariant"
[[ "$DISK_WARN_PCT" =~ ^[1-9][0-9]*$ && "$DISK_WARN_PCT" -ge 1 && "$DISK_WARN_PCT" -le 99 ]] \
  || die "CI_JANITOR_DISK_WARN_PCT must be an integer 1-99 (got '$DISK_WARN_PCT') — out-of-range mutes the high-water alarm"
[[ "$STALE_HOURS" =~ ^[1-9][0-9]*$ ]] \
  || die "CI_JANITOR_STALE_HOURS must be a positive integer (got '$STALE_HOURS') — garbage mutes the dead-agent alarm"

incomplete=0      # something could not be removed or could not be aged — sweep is partial
reclaimed=0       # count of objects actually removed (or that a dry run would remove)
age_deferred=0    # allowlist hits younger than the floor (covered residue)
kept_referenced=0 # aged allowlist hits kept as benign "in use" (covered residue)
state_unarmed=0   # agent ran but the staleness clock could not be written
disk_unmeasured=0 # agent ran but the high-water check could not read the disk
state_unknown=0   # stamp existed but was unreadable/malformed (not a measured dead-agent gap)

# --- helpers ------------------------------------------------------------------
# Docker stamps three shapes: '2026-07-14T08:22:33-05:00' (volumes),
# '2026-08-04 19:39:08 -0500 CDT' (images), and the same with nanoseconds (networks).
# The wall-clock alone is not enough: Colima's daemon TZ can differ from the Mac's,
# and stripping the offset then re-parsing as host-local makes an object look up to
# ~12h older/younger than it is — enough to put a live job under the 7h floor.
# One parser: datetime + required offset → epoch. Z/z → UTC. Offset-less fails
# closed (never guessed as host-local or UTC). [LAW:one-type-per-behavior]
# [LAW:no-ambient-temporal-coupling]
epoch_of() {
  local raw="$1" s datetime offset zflag
  s="${raw/T/ }"
  # YYYY-MM-DD HH:MM:SS, optional frac, optional whitespace, then REQUIRED
  # Z / ±HH:MM / ±HHMM. Trailing junk (e.g. " CDT") is fine. Offset is required:
  # without it we would be guessing the daemon's clock domain. [LAW:no-silent-failure]
  if [[ "$s" =~ ^([0-9]{4}-[0-9]{2}-[0-9]{2}[ ][0-9]{2}:[0-9]{2}:[0-9]{2})(\.[0-9]+)?[[:space:]]*([Zz]|[+-][0-9]{2}:?[0-9]{2}) ]]; then
    datetime="${BASH_REMATCH[1]}"
    offset="${BASH_REMATCH[3]}"
  else
    return 1
  fi
  case "$offset" in
    Z|z) zflag="+0000" ;;
    *) zflag="${offset//:/}" ;;  # -05:00 → -0500; -0500 stays
  esac
  date -j -f '%Y-%m-%d %H:%M:%S%z' "${datetime}${zflag}" +%s 2>/dev/null
}

# Host clock: launchd and STATE_FILE live on the Mac. Used only for the staleness gap.
NOW_HOST=$(date +%s)
# Daemon clock + CUTOFF are set after preflight — age comparisons must share the
# Docker daemon's clock domain with CreatedAt stamps. [LAW:no-ambient-temporal-coupling]
CUTOFF=""

# True only when the object is provably older than the floor. An unparseable timestamp
# returns FALSE — the object is kept and the run is marked incomplete. Failing closed is
# the whole safety model: never delete something whose age you could not establish.
# Too-young is also FALSE but is NOT incomplete: it increments age_deferred so high-water
# does not claim an "uncovered source" when the residue is just waiting to age in.
# [LAW:no-silent-failure] [LAW:types-are-the-program]
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
  if [[ "$epoch" -lt "$CUTOFF" ]]; then
    return 0
  fi
  age_deferred=$(( age_deferred + 1 ))
  return 1
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
  # "in use" is benign only for images/volumes (still referenced by something we keep).
  # For networks and job containers it means the orphan sweep did not finish — counting
  # that as success left orphans forever and let the run exit 0. [LAW:types-are-the-program]
  case "$err" in
    *"is being used"*|*"in use"*)
      case "$what" in
        image|volume)
          log "kept ${what}: ${label} — still in use"
          kept_referenced=$(( kept_referenced + 1 )) ;;
        *)
          warn "FAILED to remove ${what} ${label}: ${err}"
          incomplete=1 ;;
      esac ;;
    *)
      warn "FAILED to remove ${what} ${label}: ${err}"
      incomplete=1 ;;
  esac
  return 0
}

# --- preflight ----------------------------------------------------------------
docker info >/dev/null 2>&1 || die "Docker daemon unreachable (is Colima up? 'colima start')"

# Age floor shares the daemon's clock with CreatedAt. Host `date +%s` after Mac sleep
# can lead the Colima VM by hours; lag makes every object look older and can put a
# live job under the 7h minimum. Fail closed if daemon time is unreadable — same
# posture as an unparseable object stamp. [LAW:no-ambient-temporal-coupling]
daemon_now_raw=$(docker info --format '{{.SystemTime}}') \
  || die "docker info SystemTime unreadable — cannot establish the age floor"
NOW_DAEMON=$(epoch_of "$daemon_now_raw") \
  || die "could not parse daemon SystemTime '$daemon_now_raw' — cannot establish the age floor"
[[ -n "$NOW_DAEMON" ]] || die "daemon SystemTime parsed empty — cannot establish the age floor"
CUTOFF=$(( NOW_DAEMON - AGE_HOURS * 3600 ))

# Did the janitor itself stop running? Only detectable once it runs again after a gap,
# but that is precisely the case worth catching: an agent silently unloaded for weeks
# while the disk refilled. [LAW:no-silent-failure]
#
# Malformed/unreadable is NOT folded into `incomplete` (wrong label) or `was_stale`
# (exit 5 / "agent was down" requires a measured gap). It is its own latch: operator
# hears once, restamp heals, exit stays 0 if the sweep was otherwise clean.
# Missing file = first run / never armed. Host clock: launchd lives on the Mac.
# [LAW:types-are-the-program]
was_stale=0
if [[ -f "$STATE_FILE" ]]; then
  last=$(cat "$STATE_FILE" 2>/dev/null) || last=""
  if [[ "$last" =~ ^[0-9]+$ ]]; then
    gap_h=$(( (NOW_HOST - last) / 3600 ))
    if [[ "$gap_h" -gt "$STALE_HOURS" ]]; then
      was_stale=1
      warn "STALE: last run was ${gap_h}h ago (threshold ${STALE_HOURS}h) — the agent was not running. Check: launchctl print gui/\$(id -u)/com.hhouse.ci-janitor"
    fi
  else
    warn "state file $STATE_FILE is unreadable or malformed; last-run unknown (will restamp on this real run)"
    state_unknown=1
  fi
fi

mode_note=""
[[ "$DRY_RUN" -ne 0 ]] && mode_note=" [DRY RUN — nothing will be deleted]"
log "start${mode_note}: age floor ${AGE_HOURS}h, disk high-water ${DISK_WARN_PCT}%"

# --- sweep 1: orphaned Actions networks, and the containers still on them ------
# FIRST: containers pin anonymous volumes. Until they are removed, those volumes are
# not dangling and the volume sweep cannot see them. Running volumes before this left
# GBs on disk and let high-water claim an "outside" source for covered garbage.
# [LAW:dataflow-not-control-flow]
# `github_network_<hex>` is a namespace only the Actions runner creates, one per job.
# A leftover one means a job died without cleaning up. Containers attached to it are
# that job's service containers — the Postgres that squats a port.
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
    # Fail closed like every other inspect — empty members from a failed listing would
    # skip container rm, then network rm "in use" used to be treated as benign success.
    # [LAW:no-silent-failure]
    members=$(docker network inspect "$n" --format '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null) || {
      warn "skip: could not list members of network $n; keeping it (run is incomplete)"
      incomplete=1
      continue
    }
    for c in $members; do
      remove_one "orphaned job container" "$c (on $n)" docker rm -f "$c"
    done
    remove_one "network" "$n (created ${created:0:10})" docker network rm "$n"
  done <<< "$nets"
fi

# --- sweep 2: anonymous volumes orphaned by CI service containers -------------
# AFTER containers: only then are the volumes dangling. Dangling + a 64-hex name.
# Docker assigns 64-hex names only to ANONYMOUS volumes, so every named volume on this
# host (supabase_*, actual-data, odysseus_chromadb-data, buildx_*_state) is excluded by
# the shape of its name and not by a list this script would have to keep in sync with
# the machine. [LAW:types-are-the-program]
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

# --- sweep 3: untagged images -------------------------------------------------
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
  # Never treat an unmeasurable disk as a healthy one — and never launder this into
  # "something could not be swept". Same split as state_unarmed. [LAW:types-are-the-program]
  warn "could not read usage of $DOCKER_DISK via colima; the high-water check did not run this cycle"
  disk_unmeasured=1
  disk_pct=""
else
  log "docker disk ${DOCKER_DISK} is ${disk_pct}% used (high-water ${DISK_WARN_PCT}%)"
fi

# Restamp means "the agent ran," not "the sweep was clean." Stale's unique job is
# detecting silence (launchd unloaded, no notifies at all) while the disk refills.
# Gating the stamp on incomplete=0 collapsed that into "no fully-clean completion":
# a stuck volume would fire exit 3 every day *and*, after 72h, permanently false-alarm
# "agent was down" even though the agent is healthy. Incomplete stays the daily
# partial-sweep signal; the clock only answers "did the agent show up." A dry run is a
# rehearsal and must not reset the clock. [LAW:one-source-of-truth]
#
# Atomic replace (temp + mv): `>` truncates on open, so a failed mid-write would destroy
# the previous good stamp and leave an empty file — which the read side then treats as
# malformed. Soft-noting that failure let the run exit 0 with the silence alarm either
# permanently stuck or never armed. Write failure is hard: the agent ran, but the clock
# that detects its absence is unarmed. [LAW:no-silent-failure]
if [[ "$DRY_RUN" -eq 0 ]]; then
  state_dir=$(dirname "$STATE_FILE")
  state_tmp="${STATE_FILE}.tmp.$$"
  if mkdir -p "$state_dir" \
    && printf '%s' "$NOW_HOST" > "$state_tmp" \
    && mv -f "$state_tmp" "$STATE_FILE"
  then
    :
  else
    rm -f "$state_tmp" 2>/dev/null || true
    warn "could not write state file $STATE_FILE — staleness check is unarmed this cycle"
    state_unarmed=1
  fi
fi

# --- outcome ------------------------------------------------------------------
# Precedence, most-severe first; each code is a different thing for you to do.
# [LAW:types-are-the-program]
#
# Every alarm that fired is notified, then the exit code picks the most severe.
# Gating a notify on winning the cascade is how stale+high-water and
# state_unarmed+high-water each dropped a signal — the channel must carry every
# alarm; only the exit code is a single winner. [LAW:no-silent-failure]
log "done${mode_note}: ${reclaimed} object(s) $([[ "$DRY_RUN" -ne 0 ]] && echo 'would be removed' || echo 'removed')${age_deferred:+; ${age_deferred} under age floor}"

# Disk pressure and "outside source" are two facts. Exit 4 is only the outside
# diagnosis (eligible set empty, residue must be something we don't cover). Covered
# residue (young skips + benign in-use keeps) must still SHOUT about the pressure —
# silence while the disk is full of reclaimable CI garbage is the original harm —
# but must not claim an uncovered source. [LAW:types-are-the-program] [LAW:no-silent-failure]
high_water=0          # exit 4: outside source
disk_pressure_covered=0  # notify only: disk high, covered residue remains
covered_residue=$(( age_deferred + kept_referenced ))
if [[ "$DRY_RUN" -eq 0 && "$incomplete" -eq 0 && -n "$disk_pct" && "$disk_pct" -ge "$DISK_WARN_PCT" ]]; then
  if [[ "$covered_residue" -gt 0 ]]; then
    disk_pressure_covered=1
  else
    high_water=1
  fi
fi

if [[ "$was_stale" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
  notify "CI janitor had NOT run in over ${STALE_HOURS}h — the agent was down. It ran now; check the schedule."
elif [[ "$was_stale" -ne 0 ]]; then
  # Log only: dry-run does not arm the stamp, so "It ran now" would be a lie.
  warn "STALE (dry-run): agent had not run in over ${STALE_HOURS}h — notify/exit 5 held; stamp not updated"
fi
if [[ "$state_unknown" -ne 0 && "$DRY_RUN" -eq 0 && "$state_unarmed" -eq 0 ]]; then
  # Not exit 5: no gap was measured. Only claim restamped when the write succeeded.
  notify "CI janitor found a malformed last-run stamp — restamped; not a dead-agent signal. See ${LOG_FILE}."
elif [[ "$state_unknown" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
  # Write failed: STATE UNARMED notify carries the truth; don't also claim restamped.
  warn "STATE UNKNOWN: stamp was malformed and could not be rewritten this cycle"
elif [[ "$state_unknown" -ne 0 ]]; then
  warn "STATE UNKNOWN (dry-run): stamp malformed — notify held; stamp not updated"
fi
if [[ "$incomplete" -ne 0 ]]; then
  warn "INCOMPLETE: at least one object could not be removed or aged — garbage may still be accumulating"
  notify "CI janitor INCOMPLETE — something could not be swept; disk may still be filling. See ${LOG_FILE}."
fi
if [[ "$state_unarmed" -ne 0 ]]; then
  # Distinct from incomplete: the agent ran; the bookkeeping that makes silence mean
  # "agent dead" did not. [LAW:comments-carry-meaning]
  warn "STATE UNARMED: agent ran but could not write $STATE_FILE — the ${STALE_HOURS}h silence check is blind until the next successful write"
  notify "CI janitor could not arm its staleness clock. See ${LOG_FILE}."
fi
if [[ "$disk_unmeasured" -ne 0 ]]; then
  warn "DISK UNMEASURED: could not read usage of $DOCKER_DISK — high-water check did not run this cycle"
  notify "CI janitor could not measure the Docker disk — high-water check skipped. See ${LOG_FILE}."
fi
if [[ "$disk_pressure_covered" -ne 0 ]]; then
  warn "DISK PRESSURE: ${DOCKER_DISK} at ${disk_pct}% with ${covered_residue} covered CI object(s) still present (${age_deferred} under age floor, ${kept_referenced} in use) — not an outside source; they will age in or free when unreferenced"
  notify "CI janitor: disk at ${disk_pct}% — covered CI garbage still present (aging in / in use), not an outside source. See ${LOG_FILE}."
fi
if [[ "$high_water" -ne 0 ]]; then
  warn "HIGH WATER: ${DOCKER_DISK} still ${disk_pct}% used after reclaiming every eligible object — something outside these sweeps is filling it. Inspect with: docker system df -v"
  notify "CI janitor: disk still ${disk_pct}% after cleaning — something else is filling it. See ${LOG_FILE}."
fi

# Exit precedence, most-severe first. Notifies already fired above.
if [[ "$incomplete" -ne 0 || "$state_unarmed" -ne 0 || "$disk_unmeasured" -ne 0 ]]; then
  exit 3
fi
if [[ "$high_water" -ne 0 ]]; then
  exit 4
fi
if [[ "$was_stale" -ne 0 && "$DRY_RUN" -eq 0 ]]; then
  exit 5
fi
exit 0
