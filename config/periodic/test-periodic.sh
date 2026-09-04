#!/usr/bin/env bash
# test-periodic.sh — behaviour tests for periodic.sh. Run: ./test-periodic.sh
#
# Asserts the CONTRACT, never the implementation: that cycles keep happening, that the
# heartbeat tells the truth about liveness, that a hung cycle cannot stall the loop, and
# that a failing job is reported as a failing job rather than as a dead agent. A totally
# different implementation of that contract would pass this file unchanged.
# [LAW:behavior-not-structure]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PERIODIC="$DIR/periodic.sh"
TMP="$(mktemp -d)"
trap 'pkill -P $$ 2>/dev/null; rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }

echo "== invocation contract =="
"$PERIODIC" --label x --interval 1 --heartbeat "$TMP/hb" -- /nonexistent-command-xyz >/dev/null 2>&1
check "missing command exits 2" "$?" "2"
"$PERIODIC" --label x --interval 0 --heartbeat "$TMP/hb" -- /bin/true >/dev/null 2>&1
check "zero interval exits 2" "$?" "2"
"$PERIODIC" --label x --interval abc --heartbeat "$TMP/hb" -- /bin/true >/dev/null 2>&1
check "non-numeric interval exits 2" "$?" "2"
"$PERIODIC" --label x --interval 1 -- /bin/true >/dev/null 2>&1
check "missing heartbeat exits 2" "$?" "2"
# `COMMAND [ARG...]` does not say which argument is a path, so periodic.sh checks the
# executable and nothing else. An earlier version validated "the last argument" as a script,
# which rejected perfectly valid commands whose last argument is not a file — the check has
# to be sited where the shape is actually known (install-agent.sh, which reads the plist).
"$PERIODIC" --label x --interval 1 --heartbeat "$TMP/argcheck.hb" -- /bin/echo not-a-path >/dev/null 2>&1 &
ARGPID=$!
sleep 3
if kill -0 "$ARGPID" 2>/dev/null; then ok "a command whose last arg is not a path still starts"; else no "a valid command with a non-path trailing arg was rejected at startup"; fi
kill "$ARGPID" 2>/dev/null; wait "$ARGPID" 2>/dev/null

echo "== status contract =="
"$PERIODIC" --status --heartbeat "$TMP/absent" >/dev/null 2>&1
check "absent heartbeat is stale (1)" "$?" "1"
printf '%s iso lbl exit=0 interval=10 timeout=10\n' "$(date +%s)" > "$TMP/fresh"
"$PERIODIC" --status --heartbeat "$TMP/fresh" >/dev/null 2>&1
check "just-written heartbeat is fresh (0)" "$?" "0"
printf '%s iso lbl exit=0 interval=10 timeout=10\n' "$(date +%s)" > "$TMP/old"
touch -t 202001010000 "$TMP/old"
"$PERIODIC" --status --heartbeat "$TMP/old" >/dev/null 2>&1
check "ancient heartbeat is stale (1)" "$?" "1"
# A heartbeat from an older periodic.sh has no interval=/timeout=. Substituting a guessed
# threshold would answer a different question than the one asked, silently.
printf '%s iso lbl exit=0\n' "$(date +%s)" > "$TMP/legacy"
"$PERIODIC" --status --heartbeat "$TMP/legacy" >/dev/null 2>&1
check "heartbeat without interval=/timeout= fails loud (2), never a guessed bar" "$?" "2"

echo "== a long but legitimate cycle is not 'dead' (the false-STALE regression) =="
# runner-guard ships interval 120 / timeout 900: one cycle may heal three runners, each
# with a pull and a verification hold. The old bar was interval*2+60 = 300s, so an agent
# 400s into correct work read as STALE -- crying wolf during the exact incident it exists
# to handle. The bar must be interval + timeout + slack.
printf '%s iso runner-guard exit=0 interval=120 timeout=900\n' "$(date +%s)" > "$TMP/slow"
touch -t "$(date -v-400S '+%Y%m%d%H%M.%S')" "$TMP/slow"
"$PERIODIC" --status --heartbeat "$TMP/slow" >/dev/null 2>&1
check "400s old with interval=120 timeout=900 is FRESH (was falsely stale)" "$?" "0"
printf '%s iso runner-guard exit=0 interval=120 timeout=900\n' "$(date +%s)" > "$TMP/reallydead"
touch -t "$(date -v-1200S '+%Y%m%d%H%M.%S')" "$TMP/reallydead"
"$PERIODIC" --status --heartbeat "$TMP/reallydead" >/dev/null 2>&1
check "1200s old with the same config is genuinely STALE" "$?" "1"

echo "== the loop keeps cycling (the six-week bug) =="
HB="$TMP/loop.hb"; COUNT="$TMP/count"
: > "$COUNT"
cat > "$TMP/tick.sh" <<'TICK'
#!/bin/bash
echo tick >> "$1"
TICK
chmod +x "$TMP/tick.sh"
"$PERIODIC" --label loop --interval 1 --heartbeat "$HB" -- "$TMP/tick.sh" "$COUNT" >/dev/null 2>&1 &
LOOP_PID=$!
sleep 5
kill "$LOOP_PID" 2>/dev/null; wait "$LOOP_PID" 2>/dev/null
n=$(wc -l < "$COUNT" | tr -d ' ')
if [[ "$n" -ge 3 ]]; then ok "ran $n cycles in 5s at interval 1 (>=3)"; else no "only ran $n cycles in 5s (expected >=3) — THE BUG"; fi
if [[ -f "$HB" ]]; then ok "heartbeat file was written"; else no "no heartbeat written"; fi
grep -q 'exit=0' "$HB" && ok "heartbeat records the successful exit code" || no "heartbeat missing exit=0: $(cat "$HB")"

echo "== a failing job is a failing job, not a dead agent =="
HB2="$TMP/fail.hb"; C2="$TMP/count2"; : > "$C2"
cat > "$TMP/failing.sh" <<'FAILING'
#!/bin/bash
echo tick >> "$1"
exit 3
FAILING
chmod +x "$TMP/failing.sh"
"$PERIODIC" --label f --interval 1 --heartbeat "$HB2" -- "$TMP/failing.sh" "$C2" >/dev/null 2>&1 &
P2=$!
sleep 4
kill "$P2" 2>/dev/null; wait "$P2" 2>/dev/null
n2=$(wc -l < "$C2" | tr -d ' ')
if [[ "$n2" -ge 2 ]]; then ok "loop survived a job exiting non-zero ($n2 cycles)"; else no "loop died on a failing job ($n2 cycles)"; fi
grep -q 'exit=3' "$HB2" && ok "heartbeat records the job's non-zero exit as data" || no "heartbeat lost the exit code: $(cat "$HB2" 2>/dev/null)"
"$PERIODIC" --status --heartbeat "$HB2" >/dev/null 2>&1
check "a failing job still reports the agent as ALIVE" "$?" "0"

echo "== a healthy agent keeps its error log empty =="
# Reaping the timeout-killer's `sleep` makes bash announce "Terminated: 15" once per cycle
# — 720 lines a day at runner-guard's interval. An error log full of benign chatter is one
# nobody reads, which costs exactly the failure it was supposed to report.
NOISE="$TMP/noise.err"
"$PERIODIC" --label q --interval 1 --timeout 5 --heartbeat "$TMP/quiet.hb" -- /usr/bin/true >/dev/null 2>"$NOISE" &
PQ=$!
sleep 6
kill "$PQ" 2>/dev/null; wait "$PQ" 2>/dev/null
nlines=$(wc -l < "$NOISE" | tr -d ' ')
if [[ "$nlines" -eq 0 ]]; then ok "several healthy cycles wrote nothing to stderr"; else no "$nlines line(s) of stderr noise across ~5 healthy cycles: $(head -1 "$NOISE")"; fi

echo "== a hung cycle cannot stall the loop (KeepAlive's blind spot) =="
# The hung command is a uniquely-named script rather than a bare `sleep 3600`, because
# `pgrep -f 'sleep 3600'` matches any such process on the machine — including the killer
# this very supervisor spawns for a real agent configured with --timeout 3600. That made
# this assertion fail for a reason that had nothing to do with the code under test.
# A test must observe its own subtree, not the host's. [LAW:behavior-not-structure]
HB3="$TMP/hang.hb"
cat > "$TMP/hangs-forever.sh" <<'HANG'
#!/bin/bash
exec sleep 3600
HANG
chmod +x "$TMP/hangs-forever.sh"
# A distinctive timeout so the killer's own sleep is identifiable among any others.
KILLER_TIMEOUT=13
"$PERIODIC" --label h --interval 1 --timeout "$KILLER_TIMEOUT" --heartbeat "$HB3" -- "$TMP/hangs-forever.sh" >/dev/null 2>&1 &
P3=$!
sleep $(( KILLER_TIMEOUT + 6 ))
kill "$P3" 2>/dev/null; wait "$P3" 2>/dev/null
sleep 1
if [[ -f "$HB3" ]] && grep -q 'exit=timeout' "$HB3"; then ok "hung cycle was killed and recorded as exit=timeout"; else no "hung cycle stalled the loop: $(cat "$HB3" 2>/dev/null || echo '(no heartbeat)')"; fi
# Assert on the whole subtree via the unique temp path, not on the hung command's own
# argv. The killer is a FORK of periodic.sh, so it carries the supervisor's full command
# line — which contains this script's path — and matching that path alone cannot tell the
# leaked child from the leaked killer from the supervisor itself. "Nothing from this run
# survives" is both the stronger claim and the unambiguous one. [LAW:behavior-not-structure]
survivors=$(pgrep -f "$TMP" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$survivors" -eq 0 ]]; then ok "nothing from this run survived the supervisor (child and killer both reaped)"; else no "$survivors process(es) from this run leaked"; pkill -f "$TMP" 2>/dev/null; fi
# The killer subshell spawns `sleep <timeout>`; killing the subshell does NOT kill it, so
# it survives reparented to init — one orphan per cycle, forever. Observed live as five
# stray `sleep 900` under a running runner-guard.
orphans=$(pgrep -x sleep 2>/dev/null | while read -r pid; do ps -o command= -p "$pid" 2>/dev/null | grep -qx "sleep $KILLER_TIMEOUT" && echo "$pid"; done | wc -l | tr -d ' ')
if [[ "$orphans" -eq 0 ]]; then ok "the killer's own sleep was reaped (no orphan per cycle)"; else no "$orphans orphaned 'sleep $KILLER_TIMEOUT' left behind"; pkill -x -f "sleep $KILLER_TIMEOUT" 2>/dev/null; fi

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
