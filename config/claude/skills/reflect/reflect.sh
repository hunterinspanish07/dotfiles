#!/usr/bin/env bash
# Unsupervised daily driver for the `reflect` self-improvement loop.
#
# Decomposition: the deterministic miner runs HERE (in the wrapper), so the headless
# agent never needs arbitrary-Bash permission — it only reads the friction file the miner
# wrote and writes the digest. The agent runs under a least-privilege --settings file
# (reflect-settings.json): default-deny, path-scoped writes, local git only, never push.
#
# Each run gets a fresh session id so the miner can exclude this run's own transcript
# (otherwise the loop would mine itself). launchd runs with a minimal environment, so PATH
# is set explicitly; credentials resolve from the user's normal Keychain login.
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:${PATH:-}"
export REFLECT_SESSION_ID="$(uuidgen)"

SKILL_DIR="$HOME/.claude/skills/reflect"
LOG_DIR="$HOME/.local/share/claude-reflect"
mkdir -p "$LOG_DIR"
cd "$HOME" || exit 1

notify_fail() {
  # A failed daily run must be visible — launchd has no terminal, so a line buried in
  # run.log is effectively silent. Surface it natively. [LAW:no-silent-failure]
  /usr/bin/osascript -e "display notification \"$1\" with title \"reflect daily run failed\""
}

{
  echo "=== reflect run $(date -u +%FT%TZ) session=$REFLECT_SESSION_ID ==="

  # 1. Mine (wrapper subprocess — not gated by the agent's permissions).
  if ! python3 "$SKILL_DIR/mine_friction.py" --exclude-session "$REFLECT_SESSION_ID"; then
    echo "!!! reflect FAILED: friction miner errored."
    notify_fail "friction miner errored — see run.log"
    exit 1
  fi

  # 2. Judge + write digest (headless agent under least-privilege settings).
  out="$(claude -p "/reflect" \
    --session-id "$REFLECT_SESSION_ID" \
    --settings "$SKILL_DIR/reflect-settings.json" 2>&1)"
  rc=$?
  printf '%s\n' "$out"

  # claude -p exits 0 even when unauthenticated, so detect auth failure in the text too —
  # a daily job that silently no-ops is the exact failure the loop exists to prevent. [LAW:no-silent-failure]
  if [ "$rc" -ne 0 ] || printf '%s' "$out" | grep -qiE 'not logged in|please run /login|invalid api key|authentication'; then
    echo "!!! reflect FAILED (rc=$rc): headless claude errored or is unauthenticated."
    echo "!!! Fix: run 'claude login' once in a terminal so the Keychain credential exists for launchd."
    notify_fail "headless claude errored or unauthenticated (rc=$rc) — run 'claude login'"
    exit 1
  fi
  echo "=== exit $rc ==="
} >> "$LOG_DIR/run.log" 2>&1
