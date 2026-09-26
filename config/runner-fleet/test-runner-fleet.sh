#!/usr/bin/env bash
# test-runner-fleet.sh — behaviour tests for how runner-fleet is reached. Run: ./test-runner-fleet.sh
#
# Every runner doc, and the runner-guard fleet-down alert, tells the operator to run
# `runner-fleet.sh up`. That name resolves through the ~/.local/bin symlink dotbot creates,
# so the script must find its spec from wherever it is invoked — an instruction that
# cannot be followed is a broken map. [LAW:behavior-not-structure]
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

echo
echo "$pass passed, $fail failed"
[[ "$fail" -eq 0 ]]
