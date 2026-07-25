#!/usr/bin/env bash
# runner-guard.sh — external circuit breaker for self-hosted CI runners.
#
# Machine-wide infra: guards EVERY self-hosted GitHub Actions runner on this host
# (Odyssey, Grounded, HopefulTranslation, …) — matched by image, not by project — so
# it lives in the machine config repo (dotfiles), not any one app's repo.
#
# WHY THIS EXISTS
# Ephemeral GitHub Actions runners MUST run with `--restart=always`: they exit 0
# after every single job and rely on the restart to re-register for the next one.
# That restart policy is correct — and structurally blind. Docker cannot tell
# "restarting to re-register after a clean job" (exit 0) from "crash-looping on a
# broken image / dead token / OOM" (exit != 0). ht-runner sat at 2400+ restarts on
# exit 127 (missing runner binary), providing ZERO CI while pinning a core of the
# shared Colima VM — invisibly, because `docker ps` still looked fine.
#
# This guard supplies the discriminator the restart policy lacks, from outside:
# a runner is ROGUE iff it stays unhealthy — last exit non-zero AND not currently
# running a job — across the whole sampling window (a sustained crash-loop, not a
# single transient exit Docker will recover from on its own). Persistence, not restart
# velocity: Docker's backoff throttles a long loop's restart rate toward zero, so a
# rate signal misses exactly the worst cases. A rogue runner is strictly worse than no
# runner (it delivers zero CI while pinning the shared VM), so the
# heal is to STOP the loop and shout — never to silently paper over it, and never to
# recreate the container (this guard does not own any project's PAT/repo/labels;
# guessing them would be silent-wrong). [LAW:types-are-the-program] [LAW:no-silent-failure]
#
# EXIT CODES (a contract, per the CLI binding):
#   0  all runners healthy, or no runner containers present
#   1  at least one rogue runner found and circuit-broken (loud, expected signal)
#   2  the guard itself could not run (Docker unreachable) — NOT "all healthy"
set -euo pipefail

# One source of truth for "what is a runner to guard": any container built from this
# image repo. Matching by image (not by the `-runner` name convention, which can
# drift) is the true predicate, and it is what makes this machine-wide rather than
# per-project. [LAW:one-source-of-truth]
RUNNER_IMAGE_REPO="${RUNNER_IMAGE_REPO:-myoung34/github-runner}"
# The window is the guard's OWN, explicit timing: it measures *persistence* of the
# unhealthy state, the domain quantity that separates a real crash-loop from a single
# transient exit Docker recovers in seconds. It is NOT restart velocity (Docker's
# exponential backoff throttles a long-running loop's restart rate to near zero, so
# velocity has a false-negative exactly on the worst cases) and NOT a "settle" sleep.
# [LAW:no-ambient-temporal-coupling]
WINDOW_SECS="${RUNNER_GUARD_WINDOW:-20}"
LOG_FILE="${RUNNER_GUARD_LOG:-$HOME/.local/share/runner-guard/guard.log}"
# Read-only mode: classify and report every runner exactly as normal (same exit code,
# so 'exit 1 == a rogue exists' still holds), but hold the boundary effect — describe
# the circuit-break instead of performing it. For operator status checks and for
# verifying the classifier without touching the fleet. [LAW:effects-at-boundaries]
CHECK_ONLY="${RUNNER_GUARD_CHECK_ONLY:-0}"

mkdir -p "$(dirname "$LOG_FILE")" || true
# `|| true` on the tee: a logging effect (disk full, unwritable log) must NEVER abort
# the caller under `set -e` — otherwise errexit could kill the script on the `warn`
# line immediately before a heal, and the one thing this tool guarantees (stopping a
# rogue) silently wouldn't happen. Same isolation notify() already has. [LAW:effects-at-boundaries]
log()  { printf '%s runner-guard: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE" || true; }
warn() { printf '%s runner-guard: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE" >&2 || true; }
# Docker being unreachable is the guard failing, not the runners passing. Reporting
# "all healthy" here would be the silent-fallback trap: a wrong map at the worst
# moment. Fail loud, exit 2. [LAW:no-silent-failure]
die()  { warn "FATAL: $*"; exit 2; }

# Best-effort desktop alert. Its own failure must never mask a rogue finding, so it
# is isolated at this boundary and cannot abort the run. [LAW:effects-at-boundaries]
notify() {
  local msg="$1"
  osascript -e "display notification \"${msg//\"/\'}\" with title \"CI runner-guard\"" >/dev/null 2>&1 \
    || warn "note: desktop notification failed (osascript); alert is in $LOG_FILE"
}

# --- discover the fleet -------------------------------------------------------
# Validate Docker is actually reachable before trusting any emptiness downstream:
# an empty list from a dead daemon must not read as "no rogue runners".
docker info >/dev/null 2>&1 || die "Docker daemon unreachable (is Colima up? 'colima start')"

# Capture `docker ps` explicitly so its exit status is CHECKED — a process
# substitution's status is invisible to the reading shell, so `docker ps` failing
# inside `< <(...)` would yield an empty stream and read as "no runners → all healthy",
# the exact silent-fallback trap this tool exists to prevent (and most likely to fire
# under the VM load a crash-loop causes). ps failure is daemon-level → die (exit 2);
# only a genuinely empty result reaches the "nothing to guard" path. [LAW:no-silent-failure]
all_ids=$(docker ps -aq) || die "docker ps failed (VM overloaded or Docker down?)"

# Enumerate, keeping containers whose image is our runner repo. The image is referenced
# by digest, so `--filter ancestor=<repo>` (tag-based) matches nothing — match the ref
# prefix instead. (Indexed arrays + read-loop, not mapfile/assoc-arrays: portable to
# macOS bash 3.2, which /bin/bash and the launchd agent actually run.)
runners=()
while read -r cid; do
  [[ -z "$cid" ]] && continue
  # A per-container inspect failure here is a container racing away mid-scan, not a
  # daemon outage — warn loudly (never silently drop, unlike the old `|| continue`)
  # and move on; don't die and deny protection to the rest of the fleet.
  if ! img=$(docker inspect -f '{{.Config.Image}}' "$cid" 2>&1); then
    warn "skip: inspect failed for $cid during discovery ($img); not guarded this cycle"
    continue
  fi
  if [[ "$img" == "$RUNNER_IMAGE_REPO"@* || "$img" == "$RUNNER_IMAGE_REPO":* ]]; then
    runners+=("$cid")
  fi
done <<< "$all_ids"

if [[ ${#runners[@]} -eq 0 ]]; then
  log "no runner containers found (image ${RUNNER_IMAGE_REPO}); nothing to guard"
  exit 0
fi

# --- sample unhealthy-state persistence across the window ---------------------
# "unhealthy right now" = last exit non-zero AND not currently running a job.
# A healthy runner is either running, or between jobs having exited 0 — so this can
# never fire on a healthy one. Sampled at both ends of the window; rogue only if it
# PERSISTS, which rejects the single transient exit Docker recovers from.
# A single container's inspect failure is NOT exit-2 territory: exit 2 means "the
# daemon is unreachable", and one container vanishing mid-window (another project
# recreating its own runner on the shared VM) is unrelated to that. Warn and mark it
# skip so the rest of the batch is still checked — aborting the whole run here would
# deny the circuit breaker to every other runner over one unrelated race.
# [LAW:no-silent-failure] [LAW:types-are-the-program]
unhealthy0=()
for i in "${!runners[@]}"; do
  if ! s0=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${runners[$i]}" 2>&1); then
    warn "skip: inspect failed for ${runners[$i]} at t0 ($s0); not classified this cycle"
    unhealthy0[$i]=skip
    continue
  fi
  read -r st0 ex0 <<< "$s0"
  if [[ "$ex0" -ne 0 && "$st0" != "running" ]]; then unhealthy0[$i]=1; else unhealthy0[$i]=0; fi
done

sleep "$WINDOW_SECS"

# --- classify and heal --------------------------------------------------------
rogue_found=0
for i in "${!runners[@]}"; do
  id="${runners[$i]}"
  # Already unreachable at t0 — warned there; carry the skip, don't re-warn or classify.
  [[ "${unhealthy0[$i]}" == "skip" ]] && continue
  if ! s1=$(docker inspect -f '{{.Name}} {{.State.Status}} {{.State.ExitCode}} {{.RestartCount}} {{.HostConfig.RestartPolicy.Name}}' "$id" 2>&1); then
    warn "skip: inspect failed for $id at t1 ($s1); not classified this cycle"
    continue
  fi
  read -r name status exit1 rc1 rp1 <<< "$s1"
  name="${name#/}"

  # Three domain states, told apart by two gates. UNHEALTHY = bad exit AND not running
  # at BOTH samples — backoff-independent, since a deeply-throttled loop is still
  # non-zero-exit + not-running the whole window. Among the unhealthy, the restart
  # POLICY discriminates a live crash-loop Docker keeps resurrecting (policy != no)
  # from one we already circuit-broke (we set --restart=no), which now just sits parked
  # awaiting the operator. Healthy exit-0 cycling fails the exit gate. [LAW:types-are-the-program]
  if [[ "${unhealthy0[$i]}" -ne 1 || "$exit1" -eq 0 || "$status" == "running" ]]; then
    log "healthy: $name — status ${status}, exit ${exit1} (total restarts ${rc1})"
  elif [[ "$rp1" == "no" ]]; then
    # Already circuit-broken by a prior cycle: Docker is NOT restarting it, so it's not
    # a live crash-loop — parked, awaiting operator fix/recreate. Log once per cycle
    # (stays visible, never silent) but do NOT re-notify or re-heal: a breaker trips
    # once and stays open; re-alerting every 120s forever is the alert-fatigue path
    # that gets the channel muted. Not a NEW rogue, so it doesn't set rogue_found.
    # [LAW:types-are-the-program]
    log "parked: $name — already circuit-broken (status ${status}, exit ${exit1}); awaiting operator fix/recreate"
  else
    rogue_found=1
    if [[ "$CHECK_ONLY" != "0" ]]; then
      warn "ROGUE: $name — status ${status}, exit ${exit1}, unhealthy ${WINDOW_SECS}s+ (total restarts ${rc1}); WOULD circuit-break (CHECK_ONLY)"
    else
      warn "ROGUE: $name — status ${status}, exit ${exit1}, unhealthy ${WINDOW_SECS}s+ (total restarts ${rc1}); circuit-breaking"
      # Drop the always-restart policy first so Docker can't immediately resurrect it,
      # then stop. Left stopped (not removed) so logs survive for the operator to
      # root-cause and recreate. A heal failure on ONE container (concurrently
      # removed/recreated on the shared VM, transient EBUSY) is not "Docker is down":
      # warn WITH the captured docker error (every other failure path here does the
      # same) and continue — don't die (exit 2 = daemon unreachable) or abort the batch;
      # rogue_found stays 1. [LAW:effects-at-boundaries] [LAW:no-silent-failure]
      if ! err=$(docker update --restart=no "$id" 2>&1); then
        warn "heal failed: could not disable restart policy on $name ($err); will retry next cycle"; continue
      fi
      if ! err=$(docker stop "$id" 2>&1); then
        warn "heal failed: could not stop $name ($err); will retry next cycle"; continue
      fi
      warn "STOPPED: $name is halted. Root-cause it (broken image / dead PAT / OOM), then recreate per that project's runner docs (docs/CI-RUNNERS.md)."
      notify "Stopped rogue runner ${name} (exit ${exit1}, crash-looping). See ${LOG_FILE}."
    fi
  fi
done

exit "$rogue_found"
