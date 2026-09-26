#!/usr/bin/env bash
# test-alerts.sh — behaviour tests for the notifier and the session surface that reads it.
# Run: ./test-alerts.sh
#
# The contract: a raised condition reaches every new Claude Code session (to the human and
# to the agent) until it is cleared; a cleared one does not; and an empty session banner is
# only ever shown when the watchdogs that would raise alarms are actually alive.
# [LAW:behavior-not-structure]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALERTS_SH="$DIR/alerts.sh"
HOOK="$DIR/../claude/hooks/ops-alerts.sh"
PERIODIC="$DIR/../periodic/periodic.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

mkdir -p "$TMP/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$TMP/banners" > "$TMP/bin/osascript"
chmod +x "$TMP/bin/osascript"
export PATH="$TMP/bin:$PATH" ALERTS_DIR="$TMP/alerts"

fresh_hb() { printf '%s iso %s exit=0 interval=120 timeout=900\n' "$(date +%s)" "$1" > "$TMP/$1.hb"; }
fresh_hb guard; fresh_hb janitor
WATCH="guard $TMP/guard.hb
janitor $TMP/janitor.hb"
hook() { OPS_ALERTS_SH="${1:-$ALERTS_SH}" OPS_ALERTS_PERIODIC="$PERIODIC" OPS_ALERTS_WATCHDOGS="$WATCH" bash "$HOOK"; }

echo "== quiet when all is well =="
out=$(hook); rc=$?
check "no alerts + live watchdogs: hook prints nothing" "$out" ""
check "hook exits 0" "$rc" "0"

echo "== a raised condition reaches the session =="
"$ALERTS_SH" raise fleet "CI RUNNER FLEET DOWN" "ht-runner parked; run runner-fleet.sh up"
check "raise exits 0" "$?" "0"
out=$(hook)
msg=$(jq -r .systemMessage <<< "$out" 2>/dev/null)
case "$msg" in *"CI RUNNER FLEET DOWN"*ht-runner*) ok "the human sees it (systemMessage)";; *) no "systemMessage missing the alert (got: $out)";; esac
ctx=$(jq -r .hookSpecificOutput.additionalContext <<< "$out" 2>/dev/null)
case "$ctx" in *ht-runner*) ok "the agent sees it (additionalContext)";; *) no "additionalContext missing the alert";; esac
check "event name is SessionStart" "$(jq -r .hookSpecificOutput.hookEventName <<< "$out" 2>/dev/null)" "SessionStart"
"$ALERTS_SH" raise fleet "CI RUNNER FLEET DOWN" "ht-runner, odyssey-runner parked"
case "$(hook)" in *odyssey-runner*) ok "a re-raise refreshes the message";; *) no "re-raise did not refresh the message";; esac

echo "== a cleared condition leaves =="
"$ALERTS_SH" clear fleet
out=$(hook); check "after clear the hook prints nothing" "$out" ""

echo "== silence from a dead watchdog is not health =="
touch -t 202001010000 "$TMP/guard.hb"
case "$(hook)" in *"guard agent NOT RUNNING"*) ok "stale heartbeat is itself an alert";; *) no "stale watchdog passed as healthy";; esac
fresh_hb guard
rm -f "$TMP/janitor.hb"
case "$(hook)" in *"janitor agent NOT RUNNING"*) ok "missing heartbeat is itself an alert";; *) no "missing heartbeat passed as healthy";; esac
fresh_hb janitor

echo "== a broken notifier is reported, not read as 'no alerts' =="
case "$(hook /nonexistent/alerts.sh)" in *UNREADABLE*) ok "unreadable alert store is an alert";; *) no "unreadable alert store read as all-clear";; esac

echo "== ids cannot escape the alert store =="
"$ALERTS_SH" raise ../evil t m >/dev/null 2>&1
check "path-like id refused (64)" "$?" "64"
"$ALERTS_SH" bogus >/dev/null 2>&1
check "unknown command is a usage error (64)" "$?" "64"

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
