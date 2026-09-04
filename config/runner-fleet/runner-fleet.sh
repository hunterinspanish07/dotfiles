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
# How long a freshly created runner must hold still before we call the create a success.
# This is a verification window with an owner and a stated meaning — "did it survive its
# own startup" — not a settle-sleep papering over a race. A runner poisoned the way this
# fleet was poisoned exits 127 within a second or two, so a container that is still up
# and has never restarted after this long really did start. [LAW:no-ambient-temporal-coupling]
SETTLE_SECS="${RUNNER_FLEET_SETTLE:-25}"

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
# Four states, each with a distinct meaning and a distinct response. `healthy` covers
# BOTH running and cleanly-exited, because an ephemeral runner legitimately exits 0
# between jobs and waits for --restart=always to re-register it; calling that "down"
# would make `up` churn a perfectly good runner on every invocation.
# (runner-guard applies the same atomic predicate — last exit non-zero AND not running —
# but over a two-sample window, because it is asking the different question "is this a
# PERSISTENT crash loop"; this one asks "what is it right now".)
runner_state() {
  local name="$1" s
  s=$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}} {{.HostConfig.RestartPolicy.Name}}' "$name" 2>/dev/null) || { printf 'absent'; return; }
  local status exitcode policy
  read -r status exitcode policy <<< "$s"
  # Parked by runner-guard (policy dropped to 'no'): the container is deliberately not
  # coming back on its own, so from the fleet's point of view it is broken and needs
  # replacing — which is precisely the handoff the guard's circuit-break intends.
  if [[ "$policy" != "always" ]]; then printf 'broken'; return; fi
  if [[ "$status" == "running" || "$exitcode" -eq 0 ]]; then printf 'healthy'; else printf 'broken'; fi
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "docker not found on PATH ($PATH)"
  docker info >/dev/null 2>&1 || die "Docker daemon unreachable (is Colima up? 'colima start')"
}

# --- create ---------------------------------------------------------------
resolve_image() {
  log "pulling $IMAGE_SPEC to resolve an immutable digest"
  docker pull "$IMAGE_SPEC" >/dev/null || die "docker pull $IMAGE_SPEC failed"
  local digest
  digest=$(docker inspect --format='{{index .RepoDigests 0}}' "$IMAGE_SPEC") \
    || die "could not read RepoDigests for $IMAGE_SPEC"
  [[ -n "$digest" ]] || die "empty digest for $IMAGE_SPEC"
  printf '%s' "$digest"
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

  log "removing any existing $name"
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
verify_runner() {
  local name="$1" waited=0 st rc
  while [[ "$waited" -lt "$SETTLE_SECS" ]]; do
    sleep 5; waited=$((waited+5))
    st="$(runner_state "$name")"
    rc=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "?")
    if [[ "$st" == "broken" ]]; then
      warn "VERIFY FAILED: $name is $st after ${waited}s (restarts $rc). Last log lines:"
      docker logs --tail 15 "$name" 2>&1 | sed 's/^/    /' >&2
      return 1
    fi
  done
  rc=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo "?")
  if [[ "$rc" != "0" ]]; then
    warn "VERIFY FAILED: $name restarted $rc times within ${SETTLE_SECS}s — it is looping. Last log lines:"
    docker logs --tail 15 "$name" 2>&1 | sed 's/^/    /' >&2
    return 1
  fi
  log "verified: $name held healthy for ${SETTLE_SECS}s with 0 restarts"
  return 0
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
  local i st rc img degraded=0
  printf '%-18s %-10s %-9s %s\n' CONTAINER STATE RESTARTS IMAGE
  for i in "${SELECTED[@]}"; do
    st="$(runner_state "${R_NAME[$i]}")"
    rc=$(docker inspect -f '{{.RestartCount}}' "${R_NAME[$i]}" 2>/dev/null || echo -)
    img=$(docker inspect -f '{{.Config.Image}}' "${R_NAME[$i]}" 2>/dev/null | sed 's/.*@sha256:/sha256:/' | cut -c1-19 || echo -)
    printf '%-18s %-10s %-9s %s\n' "${R_NAME[$i]}" "$st" "$rc" "${img:--}"
    [[ "$st" == "healthy" ]] || degraded=1
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
  local i st image failed=0 acted=0
  # Resolve the image ONCE for the whole run, so every runner created by one invocation
  # is the same build — not whatever the registry served between two pulls.
  image="$(resolve_image)"
  log "image resolved: $image"
  for i in "${SELECTED[@]}"; do
    st="$(runner_state "${R_NAME[$i]}")"
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
