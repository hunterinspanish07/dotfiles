#!/usr/bin/env bash
# runner-fleet.sh — create and inspect this host's self-hosted GitHub Actions runners
# from the single spec in fleet.conf.
#
# WHY THIS EXISTS
# Until now no code created a runner. Each one existed only as a `docker run` snippet
# pasted in a per-repo docs/CI-RUNNERS.md, so recreating one was a human copying prose
# — and the prose had silently drifted from every live container. When all three runners
# died on 2026-09-04 the recovery procedure was itself wrong. A recipe nobody executes
# is a recipe nobody keeps true. This script executes it, so it stays true.
# [LAW:one-source-of-truth]
#
# It is also what lets runner-guard do more than park a corpse. The guard deliberately
# refused to recreate anything, and was right to: it had no idea what a given runner's
# repo, labels or PAT were, and guessing would have been silent-wrong. That was never an
# argument against healing — it was an argument against healing WITHOUT a source of
# truth. fleet.conf is that source, so the guard can now call `up --force <name>` and be
# reading the spec rather than guessing at it.
#
# EXIT CODES (a contract — each code a distinct outcome a caller can act on):
#   0  the requested runners are in the desired state
#   1  at least one runner could not be brought up (verified, not assumed)
#   2  the script could not run: Docker unreachable, spec unreadable/invalid, or a
#      required PAT file missing. Never conflated with "a runner is unhealthy".
#   3  `status` only: at least one runner is absent or broken (reporting, not failure)
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SPEC="${RUNNER_FLEET_SPEC:-$DIR/fleet.conf}"
LOG_FILE="${RUNNER_FLEET_LOG:-$HOME/.local/share/runner-fleet/fleet.log}"
# How long to wait for a freshly created runner to register. A verification window with an
# owner and a stated meaning — "did it get all the way to listening for jobs" — not a
# settle-sleep papering over a race: the wait ends the moment the evidence arrives, and
# only the failure path spends the whole budget. [LAW:no-ambient-temporal-coupling]
SETTLE_SECS="${RUNNER_FLEET_SETTLE:-60}"

# Uniform across every runner, so they are not columns in the spec. A runner that needed
# a different value here would be a different KIND of runner, and that is a schema
# change (a new column), not a per-row exception. [LAW:one-type-per-behavior]
LABELS_DEFAULT="self-hosted,linux"
WORKROOT="/runner-work"

mkdir -p "$(dirname "$LOG_FILE")" || true
log()  { printf '%s runner-fleet: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE" || true; }
warn() { printf '%s runner-fleet: %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOG_FILE" >&2 || true; }
die()  { warn "FATAL: $*"; exit 2; }

usage() {
  cat >&2 <<'USAGE'
usage:
  runner-fleet.sh status                    # classify every runner in the spec
  runner-fleet.sh up [--force] [NAME...]    # converge runners to the spec (default: all)
  runner-fleet.sh adopt [NAME...]           # recover a live container's PAT into its pat-file
  runner-fleet.sh plan [NAME...]            # print the docker run that `up` would issue

`up` replaces a runner that is absent or broken and leaves a healthy one alone;
--force replaces it regardless. Replacing always pulls the spec's IMAGE first, so
`up --force` is also how you take a new runner version (auto-update is off by design).
USAGE
}

# --- the spec is the program --------------------------------------------------
# Parsed once, into parallel indexed arrays (macOS ships bash 3.2 — no associative
# arrays, no mapfile). A malformed row is fatal, never skipped: a silently dropped row
# is a runner that quietly stops being managed. [LAW:no-silent-failure]
IMAGE_SPEC=""
R_NAME=() R_REPO=() R_RUNNER=() R_PAT=()
parse_spec() {
  [[ -r "$SPEC" ]] || die "spec not readable: $SPEC"
  local lineno=0 line kw a b c d extra
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno+1))
    line="${line%%#*}"                       # strip comments
    line="$(echo "$line" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    if [[ "$line" == IMAGE=* ]]; then
      IMAGE_SPEC="${line#IMAGE=}"
      continue
    fi
    read -r kw a b c d extra <<< "$line"
    [[ "$kw" == "runner" ]] || die "$SPEC:$lineno: expected 'IMAGE=' or 'runner <container> <owner/repo> <runner-name> <pat-file>', got '$kw'"
    [[ -n "$a" && -n "$b" && -n "$c" && -n "$d" ]] || die "$SPEC:$lineno: a runner row needs 4 fields (container repo runner-name pat-file)"
    [[ -z "$extra" ]] || die "$SPEC:$lineno: unexpected extra field '$extra'"
    [[ "$b" == */* ]] || die "$SPEC:$lineno: repo must be owner/name, got '$b'"
    R_NAME+=("$a"); R_REPO+=("$b"); R_RUNNER+=("$c"); R_PAT+=("${d/#\~/$HOME}")
  done < "$SPEC"
  [[ -n "$IMAGE_SPEC" ]]     || die "$SPEC: no IMAGE= line"
  [[ ${#R_NAME[@]} -gt 0 ]]  || die "$SPEC: no runner rows"
}

# The work dir is DERIVED, never declared — see fleet.conf. Two runners cannot collide
# on one host directory because there is no way to say that they do. [LAW:types-are-the-program]
workdir_for() { printf '%s/%s' "$WORKROOT" "${1%-runner}"; }

index_of() {
  local want="$1" i
  for i in "${!R_NAME[@]}"; do [[ "${R_NAME[$i]}" == "$want" ]] && { printf '%s' "$i"; return 0; }; done
  return 1
}

# --- one definition of what state a runner is in ------------------------------
# Classifies every SELECTED runner into STATES[], sampling at BOTH ENDS of a window.
#
# Two wrong versions of this preceded the right one, and both wrong ones are worth
# naming. A single point-in-time sample called odyssey-runner "healthy" mid-crash-loop,
# because the instant it was asked fell inside one of the restarts and the container
# really was `running` — running its own doomed entrypoint. Replacing that with a restart
# COUNT DELTA was worse: it flagged a perfectly healthy ht-runner as looping (an ephemeral
# runner legitimately exits and restarts after every job it finishes) while calling a
# genuinely dead odyssey-runner healthy, because Docker's exponential backoff had stretched
# its restart interval past the sampling window. A rate signal has a false negative exactly
# on the worst cases, which is the property you least want in this measurement.
#
# What actually separates the two is PERSISTENCE of the unhealthy condition, not its rate:
# unhealthy == last exit non-zero AND not currently running, and it has to hold at both
# ends of the window. A healthy runner is always either running or cleanly exited between
# jobs, so it can never satisfy that; a crash-loop satisfies it continuously however slowly
# Docker is resurrecting it. (This is the same predicate runner-guard uses, arrived at the
# same way — see its header. It was written down there before this file existed, and
# rediscovering it the hard way is the argument for reading it.)
# [FRAMING:representation] [LAW:no-silent-failure]
#
# The states are exhaustive and each carries its own response, so callers branch on a
# value rather than re-deriving the question:
#   absent    no such container
#   parked    restart policy is not `always` — runner-guard circuit-broke it deliberately
#   looping   unhealthy at both ends of the window: a live crash-loop
#   settling  unhealthy at exactly one end: mid-transition, not yet a verdict
#   healthy   running, or cleanly exited between jobs
# [LAW:types-are-the-program]
STATE_SAMPLE_SECS="${RUNNER_FLEET_SAMPLE:-6}"
STATES=()
classify_selected() {
  local i s status exitcode policy n
  local unhealthy0=()
  for i in "${SELECTED[@]}"; do
    if s=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "${R_NAME[$i]}" 2>/dev/null); then
      read -r status exitcode <<< "$s"
      if [[ "$exitcode" -ne 0 && "$status" != "running" ]]; then unhealthy0+=("1"); else unhealthy0+=("0"); fi
    else
      unhealthy0+=("absent")
    fi
  done
  # One sleep for the whole batch, not one per runner: the window is a property of the
  # measurement, not of any single container.
  sleep "$STATE_SAMPLE_SECS"
  STATES=(); n=0
  for i in "${SELECTED[@]}"; do
    if ! s=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.HostConfig.RestartPolicy.Name}}' "${R_NAME[$i]}" 2>/dev/null); then
      STATES+=("absent"); n=$((n+1)); continue
    fi
    read -r status exitcode policy <<< "$s"
    if [[ "$policy" != "always" ]]; then
      STATES+=("parked")
    elif [[ "$status" == "running" || "$exitcode" -eq 0 ]]; then
      STATES+=("healthy")
    elif [[ "${unhealthy0[$n]}" == "1" ]]; then
      STATES+=("looping")
    else
      STATES+=("settling")
    fi
    n=$((n+1))
  done
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH ($PATH)"
  docker info >/dev/null 2>&1 || die "Docker daemon unreachable (is Colima up? 'colima start')"
}

# --- create ---------------------------------------------------------------
# Sets IMAGE_DIGEST rather than printing it. Returning it on stdout would put this
# function's stdout on two duties at once — progress for a human and a value for the
# caller — and log() writes to stdout, so `$(resolve_image)` captured the log line INTO
# the image reference and handed docker a multi-line ref. One channel, one meaning.
# (CLI binding: stdout vs stderr semantics are a design decision, not an accident.)
IMAGE_DIGEST=""
resolve_image() {
  log "pulling $IMAGE_SPEC to resolve an immutable digest"
  docker pull "$IMAGE_SPEC" >/dev/null || die "docker pull $IMAGE_SPEC failed"
  IMAGE_DIGEST=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE_SPEC") \
    || die "could not read RepoDigests for $IMAGE_SPEC"
  # Validate the shape before it flows downstream. An external command's output is an
  # assertion about the world until something checks it; unchecked, a malformed value
  # surfaces as `docker: invalid reference format` one call later, with the actual
  # mistake nowhere in the error. [LAW:no-silent-failure]
  [[ "$IMAGE_DIGEST" == *"@sha256:"* && "$IMAGE_DIGEST" != *$'\n'* ]] \
    || die "expected a single 'repo@sha256:...' digest for $IMAGE_SPEC, got: $IMAGE_DIGEST"
}

# The bind source lives inside the Colima VM, not on macOS, so it has to be created
# there. Without it Docker invents a root-owned directory and the runner (uid 1001)
# cannot write its _actions cache — a failure that surfaces much later, as a checkout
# error, far from its cause. [LAW:no-silent-failure]
ensure_workdir() {
  local wd="$1"
  colima ssh -- sudo mkdir -p "$wd" >/dev/null 2>&1 || die "could not create $wd inside the Colima VM"
  colima ssh -- sudo chmod 777 "$wd" >/dev/null 2>&1 || die "could not chmod $wd inside the Colima VM"
}

# Emits the docker run FLAGS for one runner, one argument per line -- everything except
# the image, which the caller appends last. Shared by `plan` (which prints it) and
# `create` (which executes it) so the command that gets reviewed is the command that gets
# run. The PAT is deliberately not rendered here: `plan` must stay safe to paste into a
# terminal, an issue, or a PR. [LAW:one-source-of-truth] [LAW:effects-at-boundaries]
render_run_flags() {
  local i="$1" wd
  wd="$(workdir_for "${R_NAME[$i]}")"
  printf '%s\n' \
    run -d --restart=always --name "${R_NAME[$i]}" \
    --network host \
    -e "REPO_URL=https://github.com/${R_REPO[$i]}" \
    -e "RUNNER_NAME=${R_RUNNER[$i]}" \
    -e "RUNNER_WORKDIR=$WORKROOT" \
    -e "LABELS=$LABELS_DEFAULT" \
    -e "EPHEMERAL=true" \
    -e "DISABLE_AUTO_UPDATE=true" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$wd:$WORKROOT"
}

create_runner() {
  local i="$1" image="$2" name="${R_NAME[$i]}" pat="${R_PAT[$i]}" wd
  wd="$(workdir_for "$name")"

  [[ -r "$pat" ]] || die "PAT file missing or unreadable for $name: $pat
       Recover it from the existing container with:  $0 adopt $name
       Or create it:  pbpaste | tr -d '[:space:]' > $pat && chmod 600 $pat"
  [[ -s "$pat" ]] || die "PAT file is empty for $name: $pat"

  ensure_workdir "$wd"

  # Stop before removing, and give it time. `docker rm -f` alone sends SIGKILL, which
  # skips the entrypoint's EXIT trap — the one that deregisters the runner with GitHub —
  # and leaves a live session behind under the same RUNNER_NAME. The replacement then
  # registers fine, connects fine, and spins forever on "A session for this runner
  # already exists. Runner connect error: Conflict", which looks nothing like the
  # ungraceful teardown that actually caused it. Observed doing exactly that to
  # odyssey-runner on 2026-09-04. SIGTERM first, so the runner hangs up on its own.
  # [LAW:no-ambient-temporal-coupling]
  log "removing any existing $name (graceful stop first, so it deregisters)"
  docker stop -t 30 "$name" >/dev/null 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true

  log "creating $name (repo ${R_REPO[$i]}, workdir $wd, auto-update OFF)"
  local flags=() line
  while IFS= read -r line; do flags+=("$line"); done < <(render_run_flags "$i")
  [[ ${#flags[@]} -gt 0 ]] || die "internal: rendered no docker flags for $name"
  # ACCESS_TOKEN is injected here and only here, read straight from its 600 file into the
  # argv — never echoed, never logged, never written to a temp file. It is appended after
  # the rendered flags rather than spliced into them, so no positional assumption about
  # the rendering can ever put the token somewhere docker treats as data.
  # [LAW:effects-at-boundaries]
  local token; token="$(cat "$pat")"
  docker "${flags[@]}" -e "ACCESS_TOKEN=$token" "$image" >/dev/null \
    || { warn "docker run failed for $name"; return 1; }

  verify_runner "$name"
}

# A create is not done when docker returns an id; it is done when the runner is still
# alive after its own startup. The whole outage this script answers began with a
# container that existed, reported "Up", and was dead. Report the result of a check that
# was actually run. [LAW:verifiable-goals]
# A create is done when the runner is REGISTERED AND LISTENING, not when docker returns
# an id. The distinction is not academic: odyssey-runner was created successfully, stayed
# `running`, and sat forever in "Obtaining the token of the runner" because its PAT no
# longer worked — a container that is up and useless, which no amount of inspecting its
# state can distinguish from one that is up and working. The runner's own log is the only
# place that fact exists, so that is where it is read from. If a future image changes this
# wording the check fails CLOSED and names the string it looked for, which is a diagnosable
# five-second fix; the alternative — assuming success when the evidence is missing — is
# how a dead fleet reports itself healthy. [LAW:verifiable-goals] [LAW:no-silent-failure]
READY_MARKER="Listening for Jobs"
verify_runner() {
  local name="$1" waited=0 s status exitcode rc
  while [[ "$waited" -lt "$SETTLE_SECS" ]]; do
    sleep 5; waited=$((waited+5))
    if ! s=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.RestartCount}}' "$name" 2>/dev/null); then
      warn "VERIFY FAILED: $name disappeared ${waited}s after creation"
      return 1
    fi
    read -r status exitcode rc <<< "$s"
    # Any restart inside the settle window is disqualifying. A runner that has just been
    # created has no legitimate reason to restart — the ephemeral exit-0 cycle only
    # happens after it has actually run a job — so a moving count here is the crash-loop.
    if [[ "$rc" -gt 0 ]]; then
      warn "VERIFY FAILED: $name restarted $rc times within ${waited}s — it is looping. Last log lines:"
      docker logs --tail 15 "$name" 2>&1 | sed 's/^/    /' >&2
      return 1
    fi
    if docker logs "$name" 2>&1 | grep -q "$READY_MARKER"; then
      log "verified: $name registered and is listening for jobs (${waited}s, 0 restarts)"
      return 0
    fi
  done
  warn "VERIFY FAILED: $name never logged '$READY_MARKER' within ${SETTLE_SECS}s (status ${status}, restarts ${rc})."
  warn "  Most often this is the PAT: it must be a fine-grained token for that repo with Administration: Read & write."
  docker logs --tail 15 "$name" 2>&1 | sed 's/^/    /' >&2
  return 1
}

# --- commands -----------------------------------------------------------------
# Resolves the requested names to spec indices, into SELECTED. NOT via `$(...)` or a
# process substitution: a die() inside either is invisible to the reading shell, so an
# unknown runner name would surface as an EMPTY selection and read as "nothing to do" --
# a silent no-op standing in for a typo. Assign to a global and check the status.
# [LAW:no-silent-failure]
SELECTED=()
select_runners() {
  SELECTED=()
  local i want
  if [[ $# -eq 0 ]]; then
    for i in "${!R_NAME[@]}"; do SELECTED+=("$i"); done
    return 0
  fi
  for want in "$@"; do
    i=$(index_of "$want") || die "no runner named '$want' in $SPEC (known: ${R_NAME[*]})"
    SELECTED+=("$i")
  done
}

cmd_status() {
  select_runners "$@"
  classify_selected
  local n=0 i st rc img degraded=0
  # STATE is container liveness — it does NOT assert that GitHub can see the runner. A
  # runner can be `healthy` here and unregistered (see verify_runner). Say what is
  # measured; never let the column imply more than the measurement supports.
  printf '%-18s %-9s %-9s %s\n' CONTAINER STATE RESTARTS IMAGE
  for i in "${SELECTED[@]}"; do
    st="${STATES[$n]}"
    rc=$(docker inspect -f '{{.RestartCount}}' "${R_NAME[$i]}" 2>/dev/null || echo -)
    img=$(docker inspect -f '{{.Config.Image}}' "${R_NAME[$i]}" 2>/dev/null | sed 's/.*@sha256:/sha256:/' | cut -c1-19 || echo -)
    printf '%-18s %-9s %-9s %s\n' "${R_NAME[$i]}" "$st" "$rc" "${img:--}"
    [[ "$st" == "healthy" ]] || degraded=1
    n=$((n+1))
  done
  return $(( degraded * 3 ))
}

cmd_plan() {
  select_runners "$@"
  local i line
  for i in "${SELECTED[@]}"; do
    echo "# ${R_NAME[$i]}  (plus -e ACCESS_TOKEN=<read from ${R_PAT[$i]}>, not shown)"
    echo -n "docker"
    while IFS= read -r line; do printf ' %q' "$line"; done < <(render_run_flags "$i")
    printf ' %q\n\n' "$IMAGE_SPEC"
  done
}

cmd_up() {
  local force=0
  [[ "${1:-}" == "--force" ]] && { force=1; shift; }
  select_runners "$@"
  classify_selected
  local i st image failed=0 acted=0 n=0
  # Resolve the image ONCE for the whole run, so every runner created by one invocation
  # is the same build — not whatever the registry served between two pulls.
  resolve_image
  image="$IMAGE_DIGEST"
  log "image resolved: $image"
  for i in "${SELECTED[@]}"; do
    st="${STATES[$n]}"; n=$((n+1))
    if [[ "$st" == "healthy" && "$force" -eq 0 ]]; then
      log "ok: ${R_NAME[$i]} is healthy; leaving it alone"
      continue
    fi
    log "converging ${R_NAME[$i]}: state=$st force=$force"
    acted=1
    create_runner "$i" "$image" || { warn "could not bring up ${R_NAME[$i]}"; failed=1; }
  done
  [[ "$acted" -eq 0 ]] && log "nothing to do — every selected runner was already healthy"
  return "$failed"
}

# Recovers the PAT from a container that still exists into its spec'd pat-file. Needed
# because the PAT was only ever baked into container env: two of these files had been
# deleted after setup, so the ONLY surviving copy of those credentials was inside
# containers that the fix was about to delete. Reads env -> file, never to a terminal.
# [LAW:effects-at-boundaries]
cmd_adopt() {
  select_runners "$@"
  local i name pat token existing
  for i in "${SELECTED[@]}"; do
    name="${R_NAME[$i]}"; pat="${R_PAT[$i]}"
    if ! token=$(docker inspect -f '{{range .Config.Env}}{{if eq (slice . 0 13) "ACCESS_TOKEN="}}{{slice . 13}}{{end}}{{end}}' "$name" 2>/dev/null); then
      warn "adopt: no container named $name to read a PAT from; skipping"
      continue
    fi
    if [[ -z "$token" ]]; then warn "adopt: $name has no ACCESS_TOKEN in its env; skipping"; continue; fi
    if [[ -s "$pat" ]]; then
      existing="$(cat "$pat")"
      if [[ "$existing" == "$token" ]]; then log "adopt: $pat already matches $name; unchanged"
      else warn "adopt: $pat EXISTS and DIFFERS from $name's token; left untouched (move it aside to re-adopt)"; fi
      continue
    fi
    ( umask 077; printf '%s' "$token" > "$pat" ) || die "adopt: could not write $pat"
    chmod 600 "$pat"
    log "adopt: recovered ${#token}-char PAT from $name into $pat (mode 600)"
  done
}

main() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    status) parse_spec; require_docker; cmd_status "$@" ;;
    up)     parse_spec; require_docker; cmd_up "$@" ;;
    adopt)  parse_spec; require_docker; cmd_adopt "$@" ;;
    plan)   parse_spec; cmd_plan "$@" ;;
    ""|-h|--help|help) usage; exit 2 ;;
    *) echo "runner-fleet.sh: unknown command '$cmd'" >&2; usage; exit 2 ;;
  esac
}
main "$@"
