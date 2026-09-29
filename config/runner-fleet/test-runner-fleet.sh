#!/usr/bin/env bash
# test-runner-fleet.sh — behaviour tests for runner-fleet. Run: ./test-runner-fleet.sh
#
# Three contracts, all about the commands the fleet-down alert and runner-guard run.
# `runner-fleet.sh up` resolves through the ~/.local/bin symlink, so the script must find
# its spec from wherever it is invoked — an instruction that cannot be followed is a
# broken map. And `up` must not report failure for the recovery it exists to perform: a
# SIGKILLed runner leaves a GitHub session that outlasts the 60s settle, and the
# Conflict line that follows is that session expiring, not a bad token. And restoring a
# runner never touches the registry — `up` (what runner-guard's heal runs) creates from
# the image already on the host, while `refresh` is the one command that pulls.
# [LAW:behavior-not-structure]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
pass=0; fail=0
ok() { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no() { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }

echo "== invoked through a symlink, as it is on PATH =="
ln -s "$DIR/runner-fleet.sh" "$TMP/runner-fleet.sh"
out=$(bash "$TMP/runner-fleet.sh" plan 2>&1)
if grep -q 'spec not readable' <<< "$out"; then no "symlinked invocation cannot find fleet.conf ($out)"; else ok "symlinked invocation finds the real fleet.conf"; fi
out=$(bash "$DIR/runner-fleet.sh" plan 2>&1)
if grep -q 'spec not readable' <<< "$out"; then no "direct invocation cannot find fleet.conf"; else ok "direct invocation finds fleet.conf"; fi

# Docker is a stub on PATH. It serves one canned container whose log is a function of
# how many times verify has sampled it. verify's budget counts 5s per sample; the test
# sets the sleep between samples to 0, so the suite does not wait on the wall clock.
# Withholding "Listening for Jobs" until sample 13 is a recovery at 65s — past the 60s
# settle (12 samples), inside the session-expiry ceiling. [LAW:no-ambient-temporal-coupling]
echo
echo "== a stale GitHub session is progress, not a bad token =="
mkdir -p "$TMP/bin" "$TMP/stub"
printf '%s\n' 'token' > "$TMP/pat"
cat > "$TMP/fleet.conf" <<EOF
IMAGE=myoung34/github-runner:ubuntu-noble
runner stub-runner owner/repo stub-name $TMP/pat
EOF
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$1" in
  info|stop|rm) exit 0 ;;
  # PULL_FAILS reproduces 2026-09-06: Colima's DNS could not resolve the registry.
  pull)
    echo pull >> "$STUB/pulls"
    [[ -f "$STUB/pull_fails" ]] && { echo "Error response from daemon: Get \"https://registry-1.docker.io/v2/\": dial tcp: lookup registry-1.docker.io: no such host" >&2; exit 1; }
    exit 0 ;;
  image)
    [[ "$2" == inspect ]] || { echo "stub docker: unexpected $*" >&2; exit 1; }
    [[ -f "$STUB/no_image" ]] && { echo "Error response from daemon: No such image: ${*: -1}" >&2; exit 1; }
    # A successful inspect may still talk on stderr (a config or credential-helper notice).
    [[ -f "$STUB/inspect_warns" ]] && echo "WARNING: Error loading config file: ~/.docker/config.json: permission denied" >&2
    echo "myoung34/github-runner@sha256:deadbeef" ;;
  run) printf '%s\n' "$*" > "$STUB/run_args"; touch "$STUB/created"; exit 0 ;;
  inspect)
    fmt=""
    shift
    while [[ $# -gt 0 ]]; do
      case "$1" in
        -f|--format) fmt="$2"; shift 2 ;;
        --format=*) fmt="${1#--format=}"; shift ;;
        *) shift ;;
      esac
    done
    [[ -f "$STUB/created" ]] || { echo "no such container" >&2; exit 1; }
    case "$fmt" in
      *RestartCount*) echo "running 0 0" ;;
      *RestartPolicy*) echo "running 0 always" ;;
      *) echo "running 0" ;;
    esac
    ;;
  logs)
    n=$(cat "$STUB/log_calls" 2>/dev/null || echo 0)
    n=$((n+1))
    printf '%s\n' "$n" > "$STUB/log_calls"
    [[ "$n" -le 40 ]] || { echo "stub: verify polled $n times — the ceiling was not enforced" >&2; exit 1; }
    phase=$(cat "$STUB/phase")
    # The live runner (grounded-runner, 2026-09-26) prints the conflict line and
    # then keeps logging "√ Connected to GitHub". The conflict is in the log; it
    # is not the last line. A last-line check misses it and blames the token.
    conflict="Runner connect error: Error: Conflict. Retrying until reconnected."
    case "$phase" in
      recover)
        if [[ "$n" -le 12 ]]; then
          printf '%s\n' "A session for this runner already exists." "$conflict" "√ Connected to GitHub"
        else
          printf '%s\n' "$conflict" "√ Connected to GitHub" "Runner reconnected." "Listening for Jobs"
        fi
        ;;
      stuck) printf '%s\n' "A session for this runner already exists." "$conflict" "√ Connected to GitHub" ;;
      silent) printf '%s\n' "Obtaining the token of the runner" ;;
      *) echo "stub: unknown phase '$phase'" >&2; exit 1 ;;
    esac
    ;;
  *) echo "stub docker: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$TMP/bin/colima" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/colima"

reset_stub() { rm -f "$TMP/stub/created" "$TMP/stub/log_calls" "$TMP/stub/pulls" "$TMP/stub/run_args" "$TMP/stub/pull_fails" "$TMP/stub/no_image" "$TMP/stub/inspect_warns"; }
# fleet <phase> <args...>: one runner-fleet invocation against the stub.
fleet() {
  printf '%s\n' "$1" > "$TMP/stub/phase"; shift
  PATH="$TMP/bin:$PATH" STUB="$TMP/stub" \
    RUNNER_FLEET_SPEC="$TMP/fleet.conf" \
    RUNNER_FLEET_LOG="$TMP/fleet.log" \
    RUNNER_FLEET_SAMPLE=0 \
    RUNNER_FLEET_POLL_SLEEP=0 \
    bash "$DIR/runner-fleet.sh" "$@" >"$TMP/up.out" 2>&1
}
run_up() { reset_stub; fleet "$1" up stub-runner; }
pulls() { [[ -f "$TMP/stub/pulls" ]] && wc -l < "$TMP/stub/pulls" | tr -d ' ' || echo 0; }

run_up recover
rc=$?
out=$(cat "$TMP/up.out")
secs=$(sed -n 's/.*verified: stub-runner.*(\([0-9]*\)s,.*/\1/p' <<< "$out")
if [[ "$rc" -eq 0 && -n "$secs" && "$secs" -gt 60 ]] && ! grep -q 'could not bring up' <<< "$out"; then
  ok "Conflict past the 60s settle, then Listening: up exits 0 and verifies (${secs}s)"
else
  no "Conflict past the 60s settle, then Listening: up exits 0 and verifies (rc=$rc secs=${secs:-none}) $out"
fi

run_up stuck
rc=$?
out=$(cat "$TMP/up.out")
secs=$(sed -n "s/.*stale GitHub session.*after \([0-9]*\)s.*/\1/p" <<< "$out")
if [[ "$rc" -eq 1 && -n "$secs" && "$secs" -gt 60 ]] && ! grep -q 'Most often this is the PAT' <<< "$out"; then
  ok "Conflict past the ceiling names the stale session, not the PAT (after ${secs}s)"
else
  no "Conflict past the ceiling names the stale session, not the PAT (rc=$rc secs=${secs:-none}) $out"
fi

run_up silent
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 1 ]] && grep -q 'within 60s' <<< "$out" && grep -q 'Most often this is the PAT' <<< "$out" && ! grep -q 'stale GitHub session' <<< "$out"; then
  ok "no Conflict line: still fails at the 60s settle and names the PAT"
else
  no "no Conflict line: still fails at the 60s settle and names the PAT (rc=$rc) $out"
fi

reset_stub
PATH="$TMP/bin:$PATH" STUB="$TMP/stub" \
  RUNNER_FLEET_SPEC="$TMP/fleet.conf" RUNNER_FLEET_LOG="$TMP/fleet.log" \
  RUNNER_FLEET_SAMPLE=0 RUNNER_FLEET_POLL_SLEEP=0 RUNNER_FLEET_CONFLICT_CEILING=60 \
  bash "$DIR/runner-fleet.sh" up stub-runner >"$TMP/up.out" 2>&1
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 2 ]] && grep -q 'must be above the settle window' <<< "$out" && [[ ! -f "$TMP/stub/created" ]]; then
  ok "a ceiling that does not extend the wait is refused before any container is created"
else
  no "a ceiling that does not extend the wait is refused before any container is created (rc=$rc) $out"
fi

# `up --force <name>` is exactly what runner-guard's heal runs (runner-guard.sh,
# heal_by_recreate). Both recorded heals died at a pull while the image was on the host.
echo
echo "== a heal restores from the host's image and never pulls =="
reset_stub; touch "$TMP/stub/pull_fails"
fleet recover up --force stub-runner
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 0 ]] && grep -q 'verified: stub-runner' <<< "$out" && grep -q 'image resolved: myoung34/github-runner@sha256:deadbeef' <<< "$out"; then
  ok "registry unreachable, image on the host: the heal creates the runner and logs the digest it used"
else
  no "registry unreachable, image on the host: the heal creates the runner and logs the digest it used (rc=$rc) $out"
fi
check_pulls=$(pulls)
if [[ "$check_pulls" -eq 0 ]]; then ok "the heal never called docker pull"; else no "the heal called docker pull $check_pulls time(s)"; fi
args=$(cat "$TMP/stub/run_args" 2>/dev/null)
if grep -q -- '--pull=never' <<< "$args" && grep -q 'myoung34/github-runner@sha256:deadbeef$' <<< "$args"; then
  ok "the runner is created from that digest with --pull=never, so docker cannot pull either"
else
  no "the runner is created from that digest with --pull=never (run: ${args:-none})"
fi

reset_stub; touch "$TMP/stub/pull_fails" "$TMP/stub/inspect_warns"
fleet recover up --force stub-runner
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 0 ]] && grep -q 'image resolved: myoung34/github-runner@sha256:deadbeef$' <<< "$out"; then
  ok "a stderr notice from a successful inspect does not corrupt the digest"
else
  no "a stderr notice from a successful inspect does not corrupt the digest (rc=$rc) $out"
fi

reset_stub; touch "$TMP/stub/no_image"
fleet recover up --force stub-runner
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 2 ]] && grep -q 'runner image myoung34/github-runner:ubuntu-noble is not on this host' <<< "$out" && grep -q 'refresh' <<< "$out" && [[ ! -f "$TMP/stub/created" ]] && [[ "$(pulls)" -eq 0 ]]; then
  ok "image absent: the heal fails naming the missing image and the refresh fix, before touching the runner"
else
  no "image absent: the heal fails naming the missing image and the refresh fix (rc=$rc pulls=$(pulls)) $out"
fi

echo
echo "== refresh is the one path that pulls =="
reset_stub
fleet recover refresh stub-runner
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 0 && "$(pulls)" -eq 1 ]] && grep -q 'verified: stub-runner' <<< "$out"; then
  ok "refresh pulls IMAGE once, then replaces the runner"
else
  no "refresh pulls IMAGE once, then replaces the runner (rc=$rc pulls=$(pulls)) $out"
fi
# The old upgrade was `up --force`; `refresh --force` is that muscle memory with the verb
# swapped. --force is what refresh already means, so it is accepted, not read as a name.
reset_stub
fleet recover refresh --force stub-runner
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 0 && "$(pulls)" -eq 1 ]] && grep -q 'verified: stub-runner' <<< "$out"; then
  ok "refresh --force is refresh, not a runner named '--force'"
else
  no "refresh --force is refresh, not a runner named '--force' (rc=$rc pulls=$(pulls)) $out"
fi
reset_stub; touch "$TMP/stub/pull_fails"
fleet recover refresh stub-runner
rc=$?
out=$(cat "$TMP/up.out")
if [[ "$rc" -eq 2 ]] && grep -q 'docker pull myoung34/github-runner:ubuntu-noble failed' <<< "$out" && [[ ! -f "$TMP/stub/created" ]]; then
  ok "a refresh whose pull fails stops before replacing anything"
else
  no "a refresh whose pull fails stops before replacing anything (rc=$rc) $out"
fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
