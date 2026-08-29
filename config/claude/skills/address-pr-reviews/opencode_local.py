#!/usr/bin/env python3
"""Shared engine for the opencode-driven local PR reviewers (grok, deepseek,
glm, ...).

Every opencode reviewer is the same machine with a different model in it: the
shared `local_review` engine posts the trigger marker, gathers the diff + prior
discussion, and validates/posts the `REVIEW_COMPLETE: <N>` verdict. This module
supplies the one opencode-specific layer on top of it — the `Runner` factory and
the auth preflight — so a new opencode reviewer is a thin `<name>_provider.py`
binding of three values (model id, display label, credential). Switching
reviewers is one value in `provider.json`; adding one is a ~30-line file.
[LAW:one-type-per-behavior] the opencode invocation is ONE type; grok /
deepseek / glm are instances, differing only in configuration.

Two invocation facts are owned here, verified against the `opencode` CLI:

- `opencode run` has no `--append-system-prompt`, so the shared brief is
  prepended to the PR prompt as one stdin message rather than carried on a
  system-prompt flag. The criteria are identical; only the delivery channel
  differs from `claude_provider`.
- Read-only is enforced by a tool-GATED agent (`pr_readonly_reviewer`, defined
  in `opencode_readonly.json` and selected with `--agent`), the counterpart of
  claude's `--allowedTools` allowlist. [LAW:single-enforcer] this agent is every
  opencode reviewer's read-only boundary. Tool-gating — not a permission
  `deny` — is used deliberately: a permissive project-level `opencode.json` in
  the PR's worktree OVERRIDES an `OPENCODE_CONFIG` permission deny (verified),
  but an agent whose write/edit/patch/bash tools are absent has no write tool to
  grant, so the boundary holds even against a hostile project config.

The review text is extracted from opencode's `--format json` event stream: the
concatenation of the root session's `text` parts, in order. [LAW:effects-at-
boundaries] the parse is pure; the engine performs the one write (posting).
"""

from __future__ import annotations

import json
import os
import subprocess
from pathlib import Path

import local_review

# The read-only reviewer agent, handed to opencode via OPENCODE_CONFIG and
# selected with --agent. It disables the write/edit/patch/bash/webfetch tools,
# so the reviewer reads and searches the repo for context but cannot mutate the
# worktree under review, run commands, or hit the network. [LAW:single-enforcer]
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


def _run(model: str, prompt: str, brief: str, cwd: str) -> str:
    """Run the review read-only via opencode on `model` and return its text.
    opencode takes one combined message on stdin (brief then PR prompt); the
    read-only policy rides OPENCODE_CONFIG. [LAW:no-silent-failure] a nonzero
    exit or a timeout raises — never returns quietly for the engine to misread
    as clean."""
    if not READONLY_CONFIG.exists():
        raise RuntimeError(
            f"opencode read-only config missing: {READONLY_CONFIG}. Without it the "
            "reviewer would run with write access to the worktree under review."
        )
    env = {**os.environ, "OPENCODE_CONFIG": str(READONLY_CONFIG)}
    message = f"{brief}\n\n---\n\n{prompt}"
    try:
        proc = subprocess.run(
            [
                "opencode",
                "run",
                "--model",
                model,
                "--agent",
                READONLY_AGENT,
                "--format",
                "json",
                "--auto",
            ],
            input=message,
            text=True,
            capture_output=True,
            cwd=cwd,
            timeout=OPENCODE_TIMEOUT_S,
            env=env,
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


def runner(model: str, label: str, credential: str) -> local_review.Runner:
    """Bind one opencode reviewer: `model` in opencode's `provider/model` form,
    `label` for the trigger marker ("Grok", "DeepSeek", ...), `credential` for
    what pays for it ("the xAI subscription", "the OpenRouter API key", ...).
    Everything else — invocation, read-only boundary, timeout, verdict
    extraction — is identical across reviewers and owned by this module.
    """
    def run(prompt: str, brief: str, cwd: str) -> str:
        return _run(model, prompt, brief, cwd)

    return local_review.Runner(
        cli="opencode",
        describe=f"opencode ({model})",
        marker=(
            f"🔍 **{label} reviewer triggered** — model `{model}`, running locally "
            f"via opencode on the {credential}. Verdict to follow."
        ),
        run=run,
    )


def setup_check(
    owner: str,
    repo: str,
    run: local_review.Runner,
    auth_provider: str,
    credential_label: str,
) -> dict:
    """Engine preflight (opencode + gh + brief) plus this reviewer's two extra
    prerequisites: the read-only config file and an authenticated provider
    (`auth_provider` is the lowercase token `opencode auth list` must contain,
    e.g. "xai" or "openrouter"). [LAW:no-silent-failure] surface a missing
    credential here rather than letting `opencode run` fail cryptically
    mid-review."""
    base = local_review.setup_check(owner, repo, run)
    if not base["installed"]:
        return base
    if not READONLY_CONFIG.exists():
        return {
            "installed": False,
            "message": f"opencode read-only config missing: {READONLY_CONFIG}",
        }
    auth = subprocess.run(["opencode", "auth", "list"], capture_output=True, text=True)
    if auth.returncode != 0 or auth_provider not in auth.stdout.lower():
        return {
            "installed": False,
            "message": (
                f"{credential_label} is not authenticated in opencode — run "
                f"`opencode auth login` and add {auth_provider} before reviewing."
            ),
        }
    return {"installed": True, "message": f"{base['message']}; {credential_label} authenticated"}
