#!/usr/bin/env python3
"""claude PR review provider — runs the adversarial review LOCALLY with the
`claude` CLI on the Claude Code subscription, then posts the verdict as a PR
issue comment carrying the `REVIEW_COMPLETE: <N>` contract trailer.

From the skill's perspective this is behaviorally identical to
`opencode_provider`: same CAPABILITIES, same canonical finding shape, same
convergence on the `REVIEW_COMPLETE` trailer (resolve unsupported — the verdict
is an issue comment, not a resolvable thread). The only two differences are the
ones the user asked for: the model is Claude (Sonnet, high effort) on the
subscription instead of GPT-5.3-codex via OpenRouter, and the review runs on
this machine instead of in GitHub Actions CI. Toggle between the two by
changing one value in provider.json.

[LAW:one-source-of-truth] the review *criteria* are the single shared brief in
`opencode_trigger_prompt.md` — both reviewers judge the diff by the identical
rules, so switching providers changes the model, never the bar. Only the
*delivery* differs (this provider computes the review and posts it; opencode's
CI action posts its own), and that one difference is owned here.

[LAW:effects-at-boundaries] the pure step — the model computing the review — is
isolated: this module gathers inputs (diff, PR context) at the boundary, hands
them to `claude` as data, and performs the one write (posting the comment) at
the boundary. `claude` runs read-only (Read/Grep/Glob) and emits text; it never
posts or edits.

[LAW:no-silent-failure] a `claude` run that exits nonzero, emits no
`REVIEW_COMPLETE` trailer, or a `gh` post that fails — each halts loudly. A
missing verdict is never read as a clean, zero-finding pass.

[LAW:no-shared-mutable-globals] nothing passes trigger -> wait -> fetch through
module state. `trigger` posts the verdict comment synchronously; `fetch` reads
the newest `REVIEW_COMPLETE` comment on the PR, which — because `trigger` just
posted it — is always the current review.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

import github_threads

CAPABILITIES = {
    "resolve":     False,  # the verdict is a PR issue comment, not a resolvable thread
    "trigger":     True,   # the review runs only when explicitly invoked
    "setup_check": True,   # verifies claude + gh are usable
}

# The reviewer model and reasoning effort — Sonnet on high effort, per the
# subscription-reuse goal. Retune the local reviewer by editing these two.
MODEL = "sonnet"
EFFORT = "high"

# Read-only tools the reviewer may use to explore surrounding code: it judges
# the diff but reads callers/schemas/tests for context (the brief demands it).
# No write tools — posting the verdict is this module's job, not the model's.
ALLOWED_TOOLS = "Read Grep Glob"

# The shared adversarial brief. [LAW:one-source-of-truth] reused from the
# opencode trigger prompt (minus its leading /opencode trigger token) so both
# reviewers hold the diff to the identical bar; edit it once, both move together.
BRIEF_FILE = Path(__file__).parent / "opencode_trigger_prompt.md"

_TRIGGER_PREFIXES = ("/opencode", "/oc")

# The contract trailer — the single machine-verifiable verdict, identical to
# opencode's, so both providers converge on the same signal.
REVIEW_COMPLETE_RE = re.compile(r"REVIEW_COMPLETE:\s*(\d+)")

# claude runs synchronously inside trigger(); this caps a hung model call. A
# normal review finishes well inside it; exceeding it is a hard failure, never
# a clean pass.
CLAUDE_TIMEOUT_S = 1200

# How this local model delivers its review. The shared brief's output contract
# says "post a summary comment"; this model does not post — the harness does.
# Appended to the brief so the criteria stay shared and only delivery diverges.
_DELIVERY_ADAPTER = (
    "---\n"
    "DELIVERY — how this review is collected: You are a LOCAL reviewer with "
    "read-only tools (Read, Grep, Glob) for exploring the repository. Do NOT "
    "post comments, open review threads, or use any tool to write anything — "
    "the harness posts your review for you. Produce your ENTIRE review as your "
    "final message. Per the output contract above, its LAST line MUST be "
    "exactly `REVIEW_COMPLETE: <N>`. Your message is posted to the PR verbatim."
)


def _gh_json(*args: str):
    out = github_threads.gh(*args)
    return json.loads(out) if out else None


def _review_brief() -> str:
    """The adversarial review brief for the local model: the shared criteria
    from the opencode brief, with the delivery instruction adapted (this model
    outputs its review; it does not post it).

    [LAW:no-silent-failure] a missing brief would leave the reviewer with no
    criteria and silently diverge from the opencode bar — fail loud instead."""
    if not BRIEF_FILE.exists():
        raise RuntimeError(
            f"review brief missing: {BRIEF_FILE}. Without it the local reviewer "
            "has no criteria and would not match the opencode reviewer's bar."
        )
    brief = BRIEF_FILE.read_text().strip()
    for p in _TRIGGER_PREFIXES:
        if brief.startswith(p):
            brief = brief[len(p):].lstrip()
            break
    return f"{brief}\n\n{_DELIVERY_ADAPTER}"


def setup_check(owner: str, repo: str) -> dict:
    """Verify the local reviewer's prerequisites: the claude CLI, an
    authenticated gh, and the shared brief. [LAW:no-silent-failure] a missing
    tool is a hard stop, never an empty clean pass."""
    if not shutil.which("claude"):
        return {"installed": False,
                "message": "`claude` CLI is not on PATH — install Claude Code first."}
    if not shutil.which("gh"):
        return {"installed": False, "message": "`gh` is not on PATH — install it first."}
    auth = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
    if auth.returncode != 0:
        return {"installed": False,
                "message": f"gh is not authenticated: {auth.stderr.strip()[:500]}"}
    if not BRIEF_FILE.exists():
        return {"installed": False, "message": f"review brief missing: {BRIEF_FILE}"}
    return {"installed": True,
            "message": f"claude ({MODEL}, effort={EFFORT}) + gh ready for {owner}/{repo}"}


def _repo_root() -> str:
    """The git worktree root the skill runs in — the code `claude` reads for
    surrounding context. Falls back to CWD outside a git tree."""
    proc = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True
    )
    root = proc.stdout.strip()
    return root if proc.returncode == 0 and root else os.getcwd()


def _prior_discussion(owner: str, repo: str, pr_num: int) -> str:
    """Existing PR issue + review comments, so the reviewer honors 'do not
    re-raise concerns already discussed in this PR's threads.'"""
    issue = _gh_json(
        "api", f"repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {author: .user.login, body}]",
    ) or []
    review = _gh_json(
        "api", f"repos/{owner}/{repo}/pulls/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {author: .user.login, body}]",
    ) or []
    lines = [
        f"@{c['author']}: {(c.get('body') or '')[:4000]}"
        for c in (*issue, *review) if (c.get("body") or "").strip()
    ]
    return "\n\n".join(lines)


def _pr_prompt(owner: str, repo: str, pr_num: int) -> str:
    """The review input handed to the model: PR metadata, prior discussion, and
    the diff under review. [LAW:no-silent-failure] an empty diff is an error
    (nothing to review / inaccessible PR), never a silent clean pass."""
    meta_raw = github_threads.gh(
        "pr", "view", str(pr_num), "--repo", f"{owner}/{repo}",
        "--json", "title,body",
    )
    meta = json.loads(meta_raw) if meta_raw else {}

    diff = subprocess.run(
        ["gh", "pr", "diff", str(pr_num), "--repo", f"{owner}/{repo}"],
        capture_output=True, text=True,
    )
    if diff.returncode != 0:
        raise RuntimeError(
            f"`gh pr diff` failed for {owner}/{repo}#{pr_num}: "
            f"{diff.stderr.strip()[:500]}"
        )
    if not diff.stdout.strip():
        raise RuntimeError(
            f"`gh pr diff` returned an empty diff for {owner}/{repo}#{pr_num} — "
            "nothing to review, or the PR/diff is inaccessible."
        )

    prior = _prior_discussion(owner, repo, pr_num)
    parts = [
        f"Review pull request {owner}/{repo}#{pr_num} adversarially, per your "
        "system instructions.",
        f"Title: {meta.get('title', '')}",
        f"Description:\n{meta.get('body') or '(none)'}",
    ]
    if prior:
        parts.append(
            "Existing review discussion on this PR — do NOT re-raise concerns "
            f"already discussed here (resolved or not):\n{prior}"
        )
    parts.append(
        "You may read any file in the repository for surrounding context "
        "(callers, schemas, tests) before judging."
    )
    parts.append(f"Diff under review:\n```diff\n{diff.stdout}\n```")
    return "\n\n".join(parts)


def _run_review(owner: str, repo: str, pr_num: int) -> str:
    """Run the local Claude review and return its text, validated to carry the
    `REVIEW_COMPLETE` trailer. Pure compute: reads, never writes."""
    prompt = _pr_prompt(owner, repo, pr_num)
    try:
        proc = subprocess.run(
            ["claude", "-p",
             "--model", MODEL,
             "--effort", EFFORT,
             "--allowedTools", ALLOWED_TOOLS,
             "--append-system-prompt", _review_brief()],
            input=prompt, text=True, capture_output=True,
            cwd=_repo_root(), timeout=CLAUDE_TIMEOUT_S,
        )
    except subprocess.TimeoutExpired as e:
        raise RuntimeError(
            f"`claude` review timed out after {CLAUDE_TIMEOUT_S}s on "
            f"{owner}/{repo}#{pr_num} — do not treat this as a clean review."
        ) from e
    if proc.returncode != 0:
        raise RuntimeError(
            f"`claude` review run failed (exit {proc.returncode}) on "
            f"{owner}/{repo}#{pr_num}: {proc.stderr.strip()[:800]}"
        )
    review = (proc.stdout or "").strip()
    if not REVIEW_COMPLETE_RE.search(review):
        raise RuntimeError(
            "claude review produced no `REVIEW_COMPLETE: <N>` trailer — the "
            f"verdict is missing, not clean. stderr: {proc.stderr.strip()[:400]}"
        )
    return review


def _post_comment(owner: str, repo: str, pr_num: int, body: str,
                  pr_url: str, what: str) -> str | None:
    """Post one PR comment, confirming GitHub accepted it. [LAW:single-enforcer]
    every comment this provider writes goes through here. [LAW:no-silent-failure]
    a dropped post raises, never returns quietly."""
    proc = subprocess.run(
        ["gh", "pr", "comment", str(pr_num), "--repo", f"{owner}/{repo}",
         "--body", body],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to post the {what} on {pr_url}: {proc.stderr.strip()[:500]}"
        )
    return proc.stdout.strip() or None


def trigger(pr_url: str) -> dict:
    """Post a visible 'triggered' marker, run the local Claude review, then post
    its verdict as a PR comment.

    The marker makes the trigger observable on the PR the moment a review is
    requested — before the local review (minutes) finishes — mirroring the
    visible /opencode trigger comment. It carries no `REVIEW_COMPLETE` trailer,
    so fetch() never mistakes it for the verdict."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    marker = (
        f"🔍 **Claude reviewer triggered** — model `{MODEL}`, effort `{EFFORT}`, "
        "running locally on the Claude Code subscription. Verdict to follow."
    )
    _post_comment(owner, repo, pr_num, marker, pr_url, "trigger marker")
    review = _run_review(owner, repo, pr_num)
    posted = _post_comment(owner, repo, pr_num, review, pr_url, "review verdict")
    return {"triggered": True, "comment_url": posted}


def wait(pr_url: str) -> dict:
    """No-op: the review ran synchronously inside trigger(). Returns the head
    SHA that was reviewed, per the provider contract for synchronous backends."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    return {
        "status": "completed",
        "conclusion": "success",
        "sha": github_threads.head_sha(owner, repo, pr_num),
        "url": None,
    }


def _latest_review_comment(owner: str, repo: str, pr_num: int):
    """The current verdict: `(n, comment)` for the newest PR issue comment whose
    body carries `REVIEW_COMPLETE: <N>`, or None if none exists.

    Keyed on the contract trailer, not on author, so the verdict is found
    regardless of which account posted it. trigger() posts a fresh verdict
    immediately before fetch() runs, so the newest such comment is always the
    current review. [LAW:one-source-of-truth]"""
    comments = _gh_json(
        "api", f"repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {author: .user.login, body, created_at}]",
    ) or []
    best = None  # (created_at, n, comment)
    for c in comments:
        m = REVIEW_COMPLETE_RE.search(c.get("body") or "")
        if not m:
            continue
        if best is None or c["created_at"] > best[0]:
            best = (c["created_at"], int(m.group(1)), c)
    if best is None:
        return None
    return best[1], best[2]


def fetch(pr_url: str) -> dict:
    """Return the current review's pending findings in canonical form.

    [LAW:verifiable-goals] `N == 0` is the one signal that establishes 'clean'
    and ends the skill's loop. While `N > 0`, the whole verdict comment is one
    unresolved finding carrying every concern; the author addresses them,
    re-triggers, and the next review's N is the convergence signal.

    [LAW:no-silent-failure] no `REVIEW_COMPLETE` verdict means the review never
    ran (or its comment was dropped) — halt; never read it as a clean pass."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    verdict = _latest_review_comment(owner, repo, pr_num)
    if verdict is None:
        raise RuntimeError(
            f"No REVIEW_COMPLETE verdict comment on {owner}/{repo}#{pr_num} — "
            "call provider.trigger(pr_url) first; do not treat this as a clean, "
            "zero-finding pass."
        )
    n, comment = verdict
    if n == 0:
        return {"findings": []}
    return {"findings": [{
        "file":            None,
        "line_start":      None,
        "line_end":        None,
        "body":            comment["body"],
        "author":          comment["author"],
        "thread_id":       None,   # an issue comment is not a resolvable thread
        "is_resolved":     False,
        "thread_comments": [{"author": comment["author"], "body": comment["body"]}],
    }]}


# ---------------------------------------------------------------------------
# CLI shim — direct invocation for testing and ad-hoc runs
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="claude PR review provider (direct)")
    sub = parser.add_subparsers(dest="command", required=True)
    for name in ("trigger", "wait", "fetch"):
        p = sub.add_parser(name)
        p.add_argument("pr_url")
    p_setup = sub.add_parser("setup_check")
    p_setup.add_argument("owner")
    p_setup.add_argument("repo")

    args = parser.parse_args()
    try:
        if args.command == "setup_check":
            out = setup_check(args.owner, args.repo)
        else:
            out = globals()[args.command](args.pr_url)
        print(json.dumps(out, indent=2))
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or "").strip() or str(e)
        print(f"ERROR ({args.command}): {msg}", file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, ValueError) as e:
        print(f"ERROR ({args.command}): {e}", file=sys.stderr)
        sys.exit(1)
