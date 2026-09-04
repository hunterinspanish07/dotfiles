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

echo "== status contract =="
"$PERIODIC" --status --interval 10 --heartbeat "$TMP/absent" >/dev/null 2>&1
check "absent heartbeat is stale (1)" "$?" "1"
printf '%s iso label exit=0\n' "$(( $(date +%s) - 5 ))" > "$TMP/fresh"; touch "$TMP/fresh"
"$PERIODIC" --status --interval 10 --heartbeat "$TMP/fresh" >/dev/null 2>&1
check "just-written heartbeat is fresh (0)" "$?" "0"
touch -t 202001010000 "$TMP/old"
"$PERIODIC" --status --interval 10 --heartbeat "$TMP/old" >/dev/null 2>&1
check "ancient heartbeat is stale (1)" "$?" "1"

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
"$PERIODIC" --status --interval 1 --heartbeat "$HB2" >/dev/null 2>&1
check "a failing job still reports the agent as ALIVE" "$?" "0"

echo "== a hung cycle cannot stall the loop (KeepAlive's blind spot) =="
HB3="$TMP/hang.hb"
"$PERIODIC" --label h --interval 1 --timeout 2 --heartbeat "$HB3" -- /bin/sleep 3600 >/dev/null 2>&1 &
P3=$!
sleep 6
kill "$P3" 2>/dev/null; wait "$P3" 2>/dev/null
if [[ -f "$HB3" ]] && grep -q 'exit=timeout' "$HB3"; then ok "hung cycle was killed and recorded as exit=timeout"; else no "hung cycle stalled the loop: $(cat "$HB3" 2>/dev/null || echo '(no heartbeat)')"; fi
if pgrep -f 'sleep 3600' >/dev/null 2>&1; then no "the hung child leaked (still running)"; pkill -f 'sleep 3600'; else ok "the hung child was reaped, not leaked"; fi

echo
echo "passed: $pass   failed: $fail"
[[ "$fail" -eq 0 ]]
