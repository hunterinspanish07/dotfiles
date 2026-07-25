#!/usr/bin/env python3
"""claude PR review provider — runs the adversarial review LOCALLY with the
`claude` CLI on the Claude Code subscription, then posts the verdict as a PR
issue comment carrying the `REVIEW_COMPLETE: <N>` contract trailer.

Everything model-agnostic lives in `local_review` (the shared engine): resolving
the PR's repo root, gathering the diff + prior discussion, validating the
trailer, posting the comment, and reading the verdict back. This module supplies
the one thing that varies — the `Runner`: how *this* model is invoked. Its sibling
`grok_provider` supplies a different runner over the identical engine; switch
between them by editing one value in `provider.json`.

The invocation: `claude -p --model sonnet --effort high` with a read-only tool
allowlist (Read/Grep/Glob), the shared brief on the system prompt, and the PR
diff + context on stdin. `claude` runs read-only and emits its review as text;
the engine posts it.
"""

from __future__ import annotations

import subprocess
import sys

import local_review

# The reviewer model and reasoning effort — Sonnet on high effort, per the
# subscription-reuse goal. Retune the local reviewer by editing these two.
MODEL = "sonnet"
EFFORT = "high"

# Read-only tools the reviewer may use to explore surrounding code: it judges
# the diff but reads callers/schemas/tests for context (the brief demands it).
# `Skill` is included so the reviewer can load its law of record on demand via the
# Claude Code laws router (`Skill(laws:code|prose|prompt|ticket)`) — the same
# mechanism the human's own hook uses — rather than having the laws inlined.
# No write tools — posting the verdict is the engine's job, not the model's.
# [LAW:single-enforcer] this allowlist is claude's read-only boundary, the
# counterpart of grok's tool-gated read-only agent.
ALLOWED_TOOLS = "Read Grep Glob Skill"

# claude runs synchronously inside trigger(); this caps a hung model call. A
# normal review finishes well inside it; exceeding it is a hard failure, never
# a clean pass.
CLAUDE_TIMEOUT_S = 1200


def _run(prompt: str, brief: str, cwd: str) -> str:
    """Run the claude review read-only and return its text. The brief rides the
    system prompt; the PR diff + context ride stdin. [LAW:no-silent-failure] a
    nonzero exit or a timeout raises — never returns quietly for the engine to
    misread as a clean review."""
    try:
        proc = subprocess.run(
            ["claude", "-p",
             "--model", MODEL,
             "--effort", EFFORT,
             "--allowedTools", ALLOWED_TOOLS,
             "--append-system-prompt", brief],
            input=prompt, text=True, capture_output=True,
            cwd=cwd, timeout=CLAUDE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(
            f"`claude` review timed out after {CLAUDE_TIMEOUT_S}s — do not treat "
            "this as a clean review."
        ) from e
    if proc.returncode != 0:
        raise RuntimeError(
            f"`claude` review run failed (exit {proc.returncode}): "
            f"{proc.stderr.strip()[:800]}"
        )
    return proc.stdout or ""


RUNNER = local_review.Runner(
    cli="claude",
    describe=f"claude ({MODEL}, effort={EFFORT})",
    marker=(
        f"🔍 **Claude reviewer triggered** — model `{MODEL}`, effort `{EFFORT}`, "
        "running locally on the Claude Code subscription. Verdict to follow."
    ),
    run=_run,
)

# The engine defines the whole contract; this provider binds it to its runner.
# [LAW:one-source-of-truth] CAPABILITIES and the loop functions come from the
# engine, so a contract change moves every local provider together.
CAPABILITIES = local_review.CAPABILITIES


def setup_check(owner: str, repo: str) -> dict:
    return local_review.setup_check(owner, repo, RUNNER)


def trigger(pr_url: str) -> dict:
    return local_review.trigger(pr_url, RUNNER)


def wait(pr_url: str) -> dict:
    return local_review.wait(pr_url)


def fetch(pr_url: str) -> dict:
    return local_review.fetch(pr_url)


if __name__ == "__main__":
    local_review.cli_main(sys.modules[__name__])
