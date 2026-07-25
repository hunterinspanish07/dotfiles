#!/usr/bin/env python3
"""grok PR review provider — runs the adversarial review LOCALLY with the
`opencode` CLI driving grok-4.5 on the xAI subscription, then posts the verdict
as a PR issue comment carrying the `REVIEW_COMPLETE: <N>` contract trailer.

This is the exact sibling of `claude_provider`: same shared engine
(`local_review`), same CAPABILITIES, same canonical finding shape, same
convergence on the trailer. The ONLY difference is the `Runner` — the one seam
that varies. Where claude runs Sonnet on the Claude Code subscription, this runs
grok-4.5 on the xAI subscription via `opencode run`. Switch between the two
local reviewers by editing one value in `provider.json`
(`{"provider": "grok"}` vs `{"provider": "claude"}`). [LAW:one-source-of-truth]

Two invocation facts differ from claude and are owned here:

- `opencode run` has no `--append-system-prompt`, so the shared brief is
  prepended to the PR prompt as one stdin message rather than carried on a
  system-prompt flag. The criteria are identical; only the delivery channel
  differs.
- Read-only is enforced by a tool-GATED agent (`pr_readonly_reviewer`, defined in
  `opencode_readonly.json` and selected with `--agent`), the counterpart of
  claude's `--allowedTools` allowlist. [LAW:single-enforcer] this agent is grok's
  read-only boundary. Tool-gating — not a permission `deny` — is used
  deliberately: a permissive project-level `opencode.json` in the PR's worktree
  OVERRIDES an `OPENCODE_CONFIG` permission deny (verified), but an agent whose
  write/edit/patch/bash tools are absent has no write tool to grant, so the
  boundary holds even against a hostile project config.

The review text is extracted from opencode's `--format json` event stream: the
concatenation of the root session's `text` parts, in order. [LAW:effects-at-
boundaries] the parse is pure; the engine performs the one write (posting).
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path

import local_review

# The reviewer model, in opencode's `provider/model` form. grok-4.5 is the
# capable xAI model on the subscription. Retune the local reviewer by editing it.
MODEL = "xai/grok-4.5"

# The read-only reviewer agent, handed to opencode via OPENCODE_CONFIG and
# selected with --agent. It disables the write/edit/patch/bash/webfetch tools, so
# the reviewer reads and searches the repo for context but cannot mutate the
# worktree under review, run commands, or hit the network. [LAW:single-enforcer]
# this agent is grok's read-only boundary — tool-gating, not a permission deny,
# because a permissive project opencode.json overrides the latter but cannot
# grant a tool the agent doesn't have. Verified: a write attempt fails with
# "No write tool is available in this session", even under a hostile project config.
READONLY_CONFIG = Path(__file__).parent / "opencode_readonly.json"
READONLY_AGENT = "pr_readonly_reviewer"

# opencode runs synchronously inside trigger(); this caps a hung model call. A
# normal review finishes well inside it; exceeding it is a hard failure, never
# a clean pass. Matches claude_provider's ceiling.
OPENCODE_TIMEOUT_S = 1200


def _extract_review(stdout: str) -> str:
    """The review text from opencode's `--format json` event stream: every
    `text` part emitted by the ROOT session, concatenated in order.

    opencode emits newline-delimited JSON events; assistant prose arrives as
    `{"type":"text","sessionID":<root>,"part":{"text":...}}`. Keying on the root
    session id (the first event's) excludes any subagent chatter, whose events
    carry a different session id. [LAW:no-silent-failure] no parseable events, or
    no text at all, is a failed run — raise, never return an empty string the
    engine would read as a missing-trailer clean pass."""
    events = []
    for line in stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            events.append(json.loads(line))
        except json.JSONDecodeError as e:
            raise RuntimeError(
                f"opencode emitted a non-JSON line under --format json: {line[:200]!r} "
                f"({e})"
            ) from e
    if not events:
        raise RuntimeError("opencode produced no JSON events — the review did not run.")
    root = events[0].get("sessionID")
    parts = [
        e["part"].get("text", "")
        for e in events
        if e.get("type") == "text" and e.get("sessionID") == root
    ]
    text = "\n".join(p for p in parts if p).strip()
    if not text:
        raise RuntimeError(
            "opencode produced no assistant text — the review is empty, not clean."
        )
    return text


def _run(prompt: str, brief: str, cwd: str) -> str:
    """Run the grok review read-only via opencode and return its text. opencode
    takes one combined message on stdin (brief then PR prompt); the read-only
    policy rides OPENCODE_CONFIG. [LAW:no-silent-failure] a nonzero exit or a
    timeout raises — never returns quietly for the engine to misread as clean."""
    if not READONLY_CONFIG.exists():
        raise RuntimeError(
            f"opencode read-only config missing: {READONLY_CONFIG}. Without it the "
            "reviewer would run with write access to the worktree under review."
        )
    env = {**os.environ, "OPENCODE_CONFIG": str(READONLY_CONFIG)}
    message = f"{brief}\n\n---\n\n{prompt}"
    try:
        proc = subprocess.run(
            ["opencode", "run", "--model", MODEL, "--agent", READONLY_AGENT,
             "--format", "json"],
            input=message, text=True, capture_output=True,
            cwd=cwd, timeout=OPENCODE_TIMEOUT_S, env=env,
        )
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(
            f"`opencode` review timed out after {OPENCODE_TIMEOUT_S}s — do not "
            "treat this as a clean review."
        ) from e
    if proc.returncode != 0:
        raise RuntimeError(
            f"`opencode` review run failed (exit {proc.returncode}): "
            f"{proc.stderr.strip()[:800]}"
        )
    return _extract_review(proc.stdout or "")


RUNNER = local_review.Runner(
    cli="opencode",
    describe=f"opencode ({MODEL})",
    marker=(
        f"🔍 **Grok reviewer triggered** — model `{MODEL}`, running locally via "
        "opencode on the xAI subscription. Verdict to follow."
    ),
    run=_run,
)

# The engine defines the whole contract; this provider binds it to its runner.
# [LAW:one-source-of-truth] CAPABILITIES and the loop functions come from the
# engine, so a contract change moves every local provider together.
CAPABILITIES = local_review.CAPABILITIES


def setup_check(owner: str, repo: str) -> dict:
    """Engine preflight (opencode + gh + brief) plus grok's two extra
    prerequisites: the read-only config file and an authenticated xAI provider.
    [LAW:no-silent-failure] surface a missing xAI credential here rather than
    letting `opencode run` fail cryptically mid-review."""
    base = local_review.setup_check(owner, repo, RUNNER)
    if not base["installed"]:
        return base
    if not READONLY_CONFIG.exists():
        return {"installed": False,
                "message": f"opencode read-only config missing: {READONLY_CONFIG}"}
    auth = subprocess.run(["opencode", "auth", "list"], capture_output=True, text=True)
    if auth.returncode != 0 or "xai" not in auth.stdout.lower():
        return {"installed": False,
                "message": ("xAI is not authenticated in opencode — run "
                            "`opencode auth login` and add xAI before reviewing.")}
    return {"installed": True, "message": f"{base['message']}; xAI authenticated"}


def trigger(pr_url: str) -> dict:
    return local_review.trigger(pr_url, RUNNER)


def wait(pr_url: str) -> dict:
    return local_review.wait(pr_url)


def fetch(pr_url: str) -> dict:
    return local_review.fetch(pr_url)


if __name__ == "__main__":
    local_review.cli_main(sys.modules[__name__])
