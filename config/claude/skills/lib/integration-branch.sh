#!/usr/bin/env bash
# Print the repo's integration branch (the branch work merges INTO) to stdout.
#
# [LAW:one-source-of-truth] computed in exactly one place; `next` (the base a
# ticket's worktree branches off) and `address-pr-reviews` (the pre-merge rebase
# target) both read it here and never reimplement the detection.
#
# Why not just use the default branch: a repo's default branch is NOT a reliable
# integration target — it can default to `main` yet merge every PR into
# `staging`. So PR history is the authority; the remote default is only a last
# resort, and falling back to it is announced on stderr [LAW:no-silent-failure]
# so a wrong guess can never pass silently and send work onto the wrong base.
set -uo pipefail

modal_base() { # most common baseRefName across recent PRs in the given state (or empty)
  gh pr list --state "$1" --limit 20 --json baseRefName --jq '.[].baseRefName' \
    | sort | uniq -c | sort -rn | head -1 | awk '{print $2}'
}

if ! gh auth status >/dev/null 2>&1; then
  echo "integration-branch: gh is not authenticated — cannot read PR history" >&2
  exit 1
fi

BASE="$(modal_base merged)"
[ -n "$BASE" ] || BASE="$(modal_base open)"
if [ -z "$BASE" ]; then
  BASE="$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@refs/remotes/origin/@@')"
  [ -n "$BASE" ] && echo "integration-branch: no PRs found; fell back to remote default '$BASE' — confirm this is your merge target before branching off it" >&2
fi

if [ -z "$BASE" ]; then
  echo "integration-branch: cannot determine an integration branch (no PRs, no origin/HEAD)" >&2
  exit 1
fi
if ! git rev-parse --verify --quiet "origin/$BASE" >/dev/null; then
  echo "integration-branch: resolved '$BASE' but origin/$BASE is missing — fetch or check the remote" >&2
  exit 1
fi

printf '%s\n' "$BASE"
