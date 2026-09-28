#!/usr/bin/env bash
# test-ci-janitor.sh — behaviour tests for the janitor's disk-pressure response.
# Run: ./test-ci-janitor.sh
#
# The contract under test: when the Docker disk is at the high-water mark in space OR
# inodes, a run sweeps allowlisted CI garbage down to the 7h live-job floor instead of the
# normal 24h; below the mark it behaves as before; and a disk still at the mark after the
# sweep exits 4 with a notification naming the resource. On 2026-09-28 /var/lib/docker ran
# out of inodes at 58% space and a bytes-only check never fired. [LAW:verifiable-goals]
#
# docker and colima are stubs on PATH serving canned objects and df readings, so the real
# janitor runs end to end without touching the VM. osascript records each banner.
# [LAW:behavior-not-structure]
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JANITOR="$DIR/ci-janitor.sh"
ALERTS_SH="$(cd "$DIR/../alerts" && pwd)/alerts.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()   { printf '  ok   %s\n' "$1"; pass=$((pass+1)); }
no()   { printf '  FAIL %s\n' "$1"; fail=$((fail+1)); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else no "$1 (expected '$3', got '$2')"; fi; }
has()   { if grep -qF -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1 ('$3' not in $(basename "$2"))"; fi; }
lacks() { if grep -qF -- "$3" "$2" 2>/dev/null; then no "$1 ('$3' found in $(basename "$2"))"; else ok "$1"; fi; }

# --- stubs --------------------------------------------------------------------
# $STUB/volumes: "<name> <CreatedAt>" per dangling volume. $STUB/df: "<space> <inodes>".
# $STUB/df-after, if present, replaces $STUB/df on the first volume removal (the sweep
# freed the disk). $STUB/df-fail makes the VM df fail; $STUB/rm-fail makes every volume
# removal fail with ENOSPC. Removals are logged to $STUB/removed.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
case "$1 ${2:-}" in
  "info ")          exit 0 ;;
  "info --format")  echo "2026-09-28T12:00:00.000000000Z" ;;
  "network ls")     : ;;
  "images --filter") : ;;
  "volume ls")      awk '{print $1}' "$STUB/volumes" ;;
  "volume inspect") awk -v n="$3" '$1 == n {print $2}' "$STUB/volumes" ;;
  "volume rm")
    [[ -f "$STUB/rm-fail" ]] && { echo "Error response from daemon: remove $3: unlinkat: no space left on device" >&2; exit 1; }
    echo "$3" >> "$STUB/removed"
    grep -v "^$3 " "$STUB/volumes" > "$STUB/volumes.tmp"; mv "$STUB/volumes.tmp" "$STUB/volumes"
    [[ -f "$STUB/df-after" ]] && mv "$STUB/df-after" "$STUB/df"
    exit 0 ;;
  *) echo "stub docker: unexpected $*" >&2; exit 1 ;;
esac
EOF
cat > "$TMP/bin/colima" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "ssh -- df --output=pcent,ipcent /var/lib/docker" ]] || { echo "stub colima: unexpected $*" >&2; exit 1; }
[[ -f "$STUB/df-fail" ]] && { echo 'time="x" level=fatal msg="exit status 255"' >&2; exit 1; }
read -r space inodes < "$STUB/df"
printf 'Use%% IUse%%\n %s%%   %s%%\n' "$space" "$inodes"
EOF
cat > "$TMP/bin/osascript" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB/banners"
EOF
chmod +x "$TMP/bin/"*

# Ages are relative to the stub daemon clock (12:00Z): 3h, 10h and 30h old, plus a NAMED
# volume that is old and dangling — the Supabase case the allowlist exists for.
YOUNG=$(printf 'a%.0s' {1..64})   # 3h  — under every floor
MID=$(printf 'b%.0s' {1..64})     # 10h — kept at 24h, swept at the 7h pressure floor
OLD=$(printf 'c%.0s' {1..64})     # 30h — swept at either floor

# fresh_case <df> [volumes...] — each volume is "<name> <CreatedAt>".
fresh_case() {
  STUB="$TMP/case$((++case_n))"; mkdir -p "$STUB"
  echo "$1" > "$STUB/df"; shift
  : > "$STUB/volumes"
  local v; for v in "$@"; do echo "$v" >> "$STUB/volumes"; done
  : > "$STUB/removed"; : > "$STUB/banners"
}
case_n=0
all_volumes=(
  "$YOUNG 2026-09-28T09:00:00+00:00"
  "$MID 2026-09-28T02:00:00+00:00"
  "$OLD 2026-09-27T06:00:00+00:00"
  "supabase_edge_runtime_grounded 2026-08-01T00:00:00+00:00"
)

# run_janitor [VAR=value...] — extra env for this run; JANITOR_ARGS carries CLI flags.
# `env` because an assignment that arrives through "$@" is a word, not an assignment.
run_janitor() {
  env PATH="$TMP/bin:$PATH" STUB="$STUB" ALERTS_DIR="$STUB/alerts" \
    CI_JANITOR_ALERTS="$ALERTS_SH" CI_JANITOR_LOG="$STUB/janitor.log" \
    CI_JANITOR_STATE="$STUB/last-run" "$@" /bin/bash "$JANITOR" ${JANITOR_ARGS:-} >/dev/null 2>&1
}
removed() { sort "$STUB/removed" | tr '\n' ' ' | sed 's/ $//'; }

echo "inode pressure alone triggers a pressure sweep down to the 7h floor"
fresh_case "58 91" "${all_volumes[@]}"; echo "58 40" > "$STUB/df-after"
run_janitor; rc=$?
check "exit 0 once the sweep brings the disk under the mark" "$rc" "0"
check "10h and 30h CI volumes removed; 3h and the named volume kept" "$(removed)" "$(printf '%s\n' "$MID" "$OLD" | sort | tr '\n' ' ' | sed 's/ $//')"
has "log names inodes as the pressure" "$STUB/janitor.log" "PRESSURE: /var/lib/docker at or over the 85% mark (inodes 91%)"
lacks "space is not named as pressure at 58%" "$STUB/janitor.log" "(space 58%"
has "the run swept at the 7h floor" "$STUB/janitor.log" "age floor 7h"
check "a successful pressure sweep raises no banner" "$(wc -l < "$STUB/banners" | tr -d ' ')" "0"

echo "below the mark in both, a run keeps the normal 24h floor"
fresh_case "58 40" "${all_volumes[@]}"
run_janitor; rc=$?
check "exit 0" "$rc" "0"
check "only the 30h CI volume removed" "$(removed)" "$OLD"
lacks "no pressure sweep" "$STUB/janitor.log" "PRESSURE"
has "the run swept at the 24h floor" "$STUB/janitor.log" "age floor 24h"
has "the pressure check still ran and logged both readings" "$STUB/janitor.log" "pressure check: /var/lib/docker space 58%, inodes 40%"

echo "still over the mark after a pressure sweep exits 4 and names the resource"
fresh_case "58 91" "${all_volumes[@]}"
run_janitor; rc=$?
check "exit 4" "$rc" "4"
has "banner names inodes" "$STUB/banners" "inodes 91%"
has "banner says young CI objects are what the floor protects" "$STUB/banners" "under the 7h floor"
lacks "banner does not blame an outside source while CI residue remains" "$STUB/banners" "outside these sweeps"

ALERT="ci-docker-disk-full"
has "the full disk is held as an active alert naming inodes" "$STUB/alerts/active/$ALERT/message" "inodes 91%"
run_janitor; rc=$?
check "a second still-full run exits 4 again" "$rc" "4"
check "but banners only once while the condition holds" "$(grep -c 'CI DOCKER DISK FULL' "$STUB/banners")" "1"
touch "$STUB/df-fail"
run_janitor
if [[ -d "$STUB/alerts/active/$ALERT" ]]; then ok "an unmeasured run leaves the alert held"; else no "an unmeasured run cleared the alert"; fi
rm -f "$STUB/df-fail"; echo "58 40" > "$STUB/df"
run_janitor; rc=$?
check "the first run measured under the mark exits 0" "$rc" "0"
if [[ -d "$STUB/alerts/active/$ALERT" ]]; then no "recovery did not clear the alert"; else ok "recovery clears the alert"; fi

echo "a sweep that could not finish never claims to know what holds the disk"
fresh_case "58 91" "${all_volumes[@]}"; touch "$STUB/rm-fail"
run_janitor; rc=$?
check "exit 3 (incomplete outranks 4)" "$rc" "3"
has "the alert says the sweep did not finish" "$STUB/alerts/active/$ALERT/message" "the sweep did not finish"
lacks "the alert does not blame an outside source" "$STUB/alerts/active/$ALERT/message" "outside these sweeps"
lacks "the alert does not claim young objects are the holder" "$STUB/alerts/active/$ALERT/message" "cannot be swept yet"

echo "space alone over the mark is named as space"
fresh_case "90 40" "${all_volumes[@]}"
run_janitor; rc=$?
check "exit 4" "$rc" "4"
has "banner names space" "$STUB/banners" "space 90%"
lacks "banner does not name inodes" "$STUB/banners" "inodes 40%"

echo "both over the mark are both named"
fresh_case "90 91" "${all_volumes[@]}"
run_janitor; rc=$?
check "exit 4" "$rc" "4"
has "banner names both resources" "$STUB/banners" "space 90%, inodes 91%"

echo "nothing eligible left and still full blames an outside source"
fresh_case "58 91" "$OLD 2026-09-27T06:00:00+00:00"
run_janitor; rc=$?
check "exit 4" "$rc" "4"
check "the only eligible volume was removed" "$(removed)" "$OLD"
has "banner points outside these sweeps" "$STUB/banners" "outside these sweeps"

echo "an unmeasurable disk is never read as healthy, and gives no evidence of pressure"
fresh_case "58 91" "${all_volumes[@]}"; touch "$STUB/df-fail"
run_janitor; rc=$?
check "exit 3" "$rc" "3"
check "normal 24h floor: only the 30h volume removed" "$(removed)" "$OLD"
has "banner says the disk could not be measured" "$STUB/banners" "could not measure the Docker disk"

echo "a dry run under pressure rehearses the 7h floor and deletes nothing"
fresh_case "58 91" "${all_volumes[@]}"
JANITOR_ARGS=--dry-run run_janitor; rc=$?
check "exit 0 (dry run never raises 4)" "$rc" "0"
check "nothing removed" "$(removed)" ""
has "would remove the 10h volume" "$STUB/janitor.log" "WOULD REMOVE volume: $MID"
lacks "would not remove the 3h volume" "$STUB/janitor.log" "WOULD REMOVE volume: $YOUNG"

echo "the live-job floor still refuses to be configured below 7h"
fresh_case "58 40" "${all_volumes[@]}"
run_janitor CI_JANITOR_AGE_HOURS=6; rc=$?
check "exit 2" "$rc" "2"
check "nothing removed" "$(removed)" ""

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
