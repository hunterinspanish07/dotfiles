#!/usr/bin/env bash
# test-runner-guard.sh — behaviour tests for the guard's alerting. Run: ./test-runner-guard.sh
#
# The contract under test: a fleet that is DOWN (a runner circuit-broken and parked) is an
# ACTIVE ALERT for as long as it stays down — raised through the shared notifier, readable
# by whatever surfaces alerts to the operator — and stops being one once the fleet is whole.
# A line in guard.log is not an alert: four days of `parked:` lines is what happened on
# 2026-09-06, and nobody read them. [LAW:no-silent-failure]
#
# Docker is a stub on PATH that serves canned container states, so these tests run the
# real guard end to end without touching a real runner. osascript is a stub that records
# each banner. [LAW:behavior-not-structure]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$DIR/runner-guard.sh"
ALERTS_SH="$(cd "$DIR/../alerts" 2>/dev/null && pwd)/alerts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

# --- stubs --------------------------------------------------------------------
# Each container is one file in $STUB named by its id: "name status exit restarts policy".
# A file holding the single word FAIL makes every inspect of that id fail.
mkdir -p "$TMP/bin" "$TMP/stub"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1" in
  info)   exit 0 ;;
  ps)     ls "$STUB" ;;
  stop|update) exit 0 ;;
  inspect)
    fmt="$3"; id="$4"; spec=$(cat "$STUB/$id" 2>/dev/null) || { echo "no such container" >&2; exit 1; }
    [[ "$spec" == FAIL ]] && { echo "inspect failed" >&2; exit 1; }
    read -r name status code rc policy <<< "$spec"
    case "$fmt" in
      '{{.Config.Image}}') echo "myoung34/github-runner:latest" ;;
      '{{.State.Status}} {{.State.ExitCode}}') echo "$status $code" ;;
      *) echo "/$name $status $code $rc $policy" ;;
    esac ;;
  *) echo "stub docker: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$TMP/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$BANNERS"
EOF
chmod +x "$TMP/bin/docker" "$TMP/bin/osascript"

run_guard() {
  PATH="$TMP/bin:$PATH" STUB="$TMP/stub" BANNERS="$TMP/banners" \
  ALERTS_DIR="$TMP/alerts" RUNNER_GUARD_ALERTS="$ALERTS_SH" \
  RUNNER_GUARD_WINDOW=0 RUNNER_GUARD_LOG="$TMP/guard.log" \
  RUNNER_FLEET_SCRIPT=/nonexistent RUNNER_GUARD_HEAL_STATE="$TMP/heals" \
  "$@" /bin/bash "$GUARD" >/dev/null 2>&1
}
set_runner() { printf '%s\n' "$2" > "$TMP/stub/$1"; }
banners() { [[ -f "$TMP/banners" ]] && wc -l < "$TMP/banners" | tr -d ' ' || echo 0; }
alert_active() { [[ -f "$TMP/alerts/active/runner-fleet-down/message" ]] && echo yes || echo no; }
alert_text() { cat "$TMP/alerts/active/runner-fleet-down/message" 2>/dev/null; }

echo "== a parked fleet is an alert, not a log line =="
set_runner c1 "ht-runner exited 1 17 no"
set_runner c2 "grounded-runner exited 0 3 always"
run_guard env
check "parked runner: guard exit 0 (nothing newly actionable)" "$?" "0"
check "parked runner raises the fleet-down alert" "$(alert_active)" "yes"
case "$(alert_text)" in *ht-runner*runner-fleet.sh\ up*) ok "alert names the runner and the fix";;
  *) no "alert names the runner and the fix (got: $(alert_text))";; esac
case "$(alert_text)" in *grounded-runner*) no "alert names a HEALTHY runner";; *) ok "alert omits the healthy runner";; esac
check "the alert fires a banner when raised" "$(banners)" "1"

echo "== it stays raised while the fleet stays down, without spamming =="
run_guard env
check "still parked: alert still active" "$(alert_active)" "yes"
check "still parked within the reminder interval: no second banner" "$(banners)" "1"
run_guard env ALERTS_REMIND_SECS=0
check "reminder interval elapsed: banner fires again" "$(banners)" "2"

echo "== an incomplete look cannot clear it =="
set_runner c1 FAIL
run_guard env
check "inspect failed: exit 4" "$?" "4"
check "inspect failed: the alert is NOT cleared on a partial assessment" "$(alert_active)" "yes"

echo "== recovery clears it =="
set_runner c1 "ht-runner exited 0 0 always"
run_guard env
check "fleet healthy: alert cleared" "$(alert_active)" "no"

echo "== read-only mode holds every effect =="
set_runner c1 "ht-runner exited 1 17 no"
run_guard env RUNNER_GUARD_CHECK_ONLY=1
check "CHECK_ONLY on a parked fleet raises nothing" "$(alert_active)" "no"

echo "== a notifier that is missing is loud, and never stops the guard =="
set_runner c1 "ht-runner exited 1 17 no"
PATH="$TMP/bin:$PATH" STUB="$TMP/stub" BANNERS="$TMP/banners" ALERTS_DIR="$TMP/alerts" \
  RUNNER_GUARD_ALERTS=/nonexistent/alerts.sh RUNNER_GUARD_WINDOW=0 RUNNER_GUARD_LOG="$TMP/guard2.log" \
  RUNNER_FLEET_SCRIPT=/nonexistent RUNNER_GUARD_HEAL_STATE="$TMP/heals" /bin/bash "$GUARD" >/dev/null 2>&1
check "missing notifier: guard still completes its cycle (exit 0)" "$?" "0"
if grep -q 'alert NOT raised' "$TMP/guard2.log"; then ok "missing notifier is logged as an unraised alert"; else no "missing notifier failed silently"; fi

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
