#!/usr/bin/env python3
"""glm PR review provider — runs the adversarial review LOCALLY with the
`opencode` CLI driving glm-5.3-flash on the OpenRouter API key, then posts the
verdict as a PR issue comment carrying the `REVIEW_COMPLETE: <N>` contract
trailer.

A thin binding of `opencode_local`, the one shared machine for every
opencode-driven reviewer — invocation, read-only boundary, timeout, verdict
extraction, and auth preflight all live there. This file contributes only the
three values that make glm glm: the model, the display label, and the
credential. Switch reviewers by editing one value in `provider.json`
(`{"provider": "grok"}` ↔ `{"provider": "deepseek"}` ↔ `{"provider": "glm"}` ↔
`{"provider": "claude"}`); the loop does not change.
[LAW:one-type-per-behavior] [LAW:one-source-of-truth]
"""

from __future__ import annotations

import sys

import local_review
import opencode_local

# The reviewer model, in opencode's `provider/model` form. Retune by editing
# this one line.
MODEL = "openrouter/z-ai/glm-5.3-flash"
LABEL = "GLM"
CREDENTIAL = "OpenRouter API key"
AUTH_PROVIDER = "openrouter"

RUNNER = opencode_local.runner(MODEL, LABEL, CREDENTIAL)

# The engine defines the whole contract; this provider binds it to its runner.
# [LAW:one-source-of-truth] CAPABILITIES and the loop functions come from the
# engine, so a contract change moves every local provider together.
CAPABILITIES = local_review.CAPABILITIES


def setup_check(owner: str, repo: str) -> dict:
    return opencode_local.setup_check(owner, repo, RUNNER, AUTH_PROVIDER, CREDENTIAL)


def trigger(pr_url: str) -> dict:
    return local_review.trigger(pr_url, RUNNER)


def wait(pr_url: str) -> dict:
    return local_review.wait(pr_url)


def fetch(pr_url: str) -> dict:
    return local_review.fetch(pr_url)


if __name__ == "__main__":
    local_review.cli_main(sys.modules[__name__])
