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
  #
  # A cycle's whole job is to append one entry to digest.md, so a grown digest IS the
  # postcondition — the one authoritative signal for "did the work land". It replaces the
  # previous grep over the agent's own prose, which could not distinguish an auth FAILURE
  # from a digest DISCUSSING one and so false-failed 18 consecutive runs by matching its
  # own report text. [LAW:one-source-of-truth] [LAW:verifiable-goals]
  digest="$LOG_DIR/digest.md"
  touch "$digest"   # always present, so the size reads below need no absence guard
  size_before="$(wc -c < "$digest")"

  # The session id is the only thing that varies per attempt, so it crosses as a value
  # rather than as a branch. [LAW:dataflow-not-control-flow]
  attempt() {
    claude -p "/reflect" \
      --session-id "$1" \
      --settings "$SKILL_DIR/reflect-settings.json" 2>&1
  }

  out="$(attempt "$REFLECT_SESSION_ID")"
  rc=$?
  printf '%s\n' "$out"

  # Every observed death was transient (connection closed mid-response, computer slept)
  # and left no entry behind, costing a full day of history. Retry on the postcondition,
  # not on rc: a run that already wrote its entry needs no second pass. The retry takes a
  # fresh session id, which the miner auto-excludes (it skips any session that ran
  # /reflect), so a retry can never leak into the window it will later mine.
  if [ "$(wc -c < "$digest")" -le "$size_before" ]; then
    echo "--- no digest entry written (rc=$rc); retrying once after 30s backoff ---"
    sleep 30
    out="$(attempt "$(uuidgen)")"
    rc=$?
    printf '%s\n' "$out"
  fi

  size_after="$(wc -c < "$digest")"
  # Report what is actually known — no entry — rather than asserting a cause the wrapper
  # cannot observe; auth is offered as the likeliest hypothesis. [LAW:no-silent-failure]
  if [ "$size_after" -le "$size_before" ]; then
    echo "!!! reflect FAILED (rc=$rc): no cycle entry was appended to digest.md."
    echo "!!! If the output above shows a login or credential error, run 'claude login'"
    echo "!!! once in a terminal so the Keychain credential exists for launchd."
    notify_fail "reflect wrote no digest entry (rc=$rc) — see run.log"
    exit 1
  fi
  echo "=== exit $rc (digest ${size_before}B -> ${size_after}B) ==="
} >> "$LOG_DIR/run.log" 2>&1
