#!/usr/bin/env python3
"""opencode PR review provider — drives the repo's `opencode` GitHub Actions
reviewer (`.github/workflows/opencode.yml`, the `anomalyco/opencode/github`
action) and reads its verdict from the review comment it posts.

This is the one provider that differs from the canonical `adversarial` provider;
every other file in this skill is unchanged. The difference is forced by how the
two reviewers deliver findings:

- The `adversarial` provider posts a formal GitHub review with inline,
  *resolvable* review threads, so it reuses `github_threads.fetch`/`resolve`.
- opencode (observed in real PRs, not assumed) posts a single PR **issue
  comment** whose last line is the contract trailer `REVIEW_COMPLETE: <N>` — it
  does **not** open resolvable review threads. So `fetch` reads that comment and
  keys convergence on N, and `resolve` is unsupported (an issue comment is not a
  thread). The author's loop still goes back and forth until clean: while N > 0
  the agent fixes, re-triggers, and the next review's N is the new signal.

[LAW:effects-at-boundaries] this module only acts: it posts the `/opencode`
trigger comment (carrying the adversarial-review brief) and polls the Actions
API. The review runs remotely in CI; nothing here computes findings.

[LAW:one-source-of-truth] the `REVIEW_COMPLETE` trailer the trigger brief
mandates is the single machine-verifiable signal of done. A bare `/opencode`
makes the reviewer summarize instead of review, so the trigger body is always
the full brief from `opencode_trigger_prompt.md`, never a bare token.
[LAW:no-silent-failure] a completed review that posted no trailer is a missing
verdict, not a clean pass — it halts.

Correlation is stateless and survives a process boundary: the workflow fires on
an `issue_comment` containing `/opencode` (or `/oc`), and an issue-comment run's
own `head_sha` is the default branch, never the PR head. So `wait` cannot key on
run head SHA. Instead it keys on the **triggering comment** — the newest
`/opencode` comment on the PR is the authoritative "when this review was
requested", and the matching run is the first opencode run created at/after it.
`fetch` keys on that same trigger timestamp: opencode's verdict is the newest
non-trigger comment carrying `REVIEW_COMPLETE` created at/after it.
[LAW:no-shared-mutable-globals] no module state passes trigger -> wait -> fetch.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from pathlib import Path

import github_threads

CAPABILITIES = {
    "resolve":     False,  # opencode posts an issue comment, not a resolvable thread
    "trigger":     True,   # the reviewer runs only when /opencode is posted
    "setup_check": True,   # verifies gh + the opencode workflow is installed
}

# The workflow file that defines the reviewer. setup_check and wait both key
# off this one name. [LAW:one-source-of-truth]
WORKFLOW_FILE = "opencode.yml"

# The adversarial-review brief opencode runs against, posted as the trigger
# body. Kept in a sibling file so the prompt is edited as prose, not wrestled as
# a Python string literal — mirrors adversarial_prompt.md. [LAW:one-source-of-truth]
TRIGGER_PROMPT_FILE = Path(__file__).parent / "opencode_trigger_prompt.md"

# Comment-body prefixes that fire the workflow, per opencode.yml's `if:`.
_TRIGGER_PREFIXES = ("/opencode", "/oc")

# The contract trailer the trigger brief mandates. opencode's verdict is read
# from this, never from inline threads (which this reviewer does not post).
REVIEW_COMPLETE_RE = re.compile(r"REVIEW_COMPLETE:\s*(\d+)")

# Poll cadence and ceiling for wait(). A CI review of a normal diff finishes
# well inside this; exceeding it is a hard failure, never a silent clean pass.
POLL_INTERVAL_S = 10
WAIT_TIMEOUT_S = 1800


def _trigger_body() -> str:
    """The `/opencode` trigger comment body — the full adversarial brief.

    [LAW:no-silent-failure] a missing prompt file would otherwise degrade to a
    bare `/opencode`, which makes opencode summarize instead of review — the
    exact regression this provider exists to prevent. Fail loud instead."""
    if not TRIGGER_PROMPT_FILE.exists():
        raise RuntimeError(
            f"opencode trigger prompt missing: {TRIGGER_PROMPT_FILE}. Without it "
            "the trigger would be a bare /opencode and opencode would summarize, "
            "not review."
        )
    body = TRIGGER_PROMPT_FILE.read_text().strip()
    if not _is_trigger(body):
        raise RuntimeError(
            f"{TRIGGER_PROMPT_FILE} must start with '/opencode' so the workflow "
            "fires and the comment is recognized as a trigger."
        )
    return body


def _gh_json(*args: str):
    out = github_threads.gh(*args)
    return json.loads(out) if out else None


def _is_trigger(body: str) -> bool:
    body = (body or "").strip()
    return any(body.startswith(p) for p in _TRIGGER_PREFIXES)


def setup_check(owner: str, repo: str) -> dict:
    """Verify gh is usable and the opencode workflow exists in this repo.
    [LAW:no-silent-failure] a missing workflow is the failure that would
    otherwise look like 'clean review, zero findings' — surface it hard."""
    import shutil

    if not shutil.which("gh"):
        return {"installed": False, "message": "`gh` is not on PATH — install it first."}
    auth = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
    if auth.returncode != 0:
        return {"installed": False,
                "message": f"gh is not authenticated: {auth.stderr.strip()[:500]}"}

    probe = subprocess.run(
        ["gh", "api", f"repos/{owner}/{repo}/actions/workflows/{WORKFLOW_FILE}"],
        capture_output=True, text=True,
    )
    if probe.returncode != 0:
        return {
            "installed": False,
            "message": (
                f"opencode workflow not found at .github/workflows/{WORKFLOW_FILE} "
                f"in {owner}/{repo} — the reviewer is not installed. "
                f"({probe.stderr.strip()[:300]})"
            ),
        }
    # `gh api --jq` emits scalar strings raw (unquoted), so read .state as a
    # plain string — never json.loads it. [LAW:no-silent-failure]
    state = github_threads.gh(
        "api", f"repos/{owner}/{repo}/actions/workflows/{WORKFLOW_FILE}", "--jq", ".state"
    )
    if state and state != "active":
        return {"installed": False,
                "message": f"opencode workflow exists but is '{state}', not active."}
    if not TRIGGER_PROMPT_FILE.exists():
        return {"installed": False,
                "message": f"opencode trigger prompt missing: {TRIGGER_PROMPT_FILE}"}
    return {"installed": True, "message": f"gh ready; {WORKFLOW_FILE} active in {owner}/{repo}"}


def trigger(pr_url: str) -> dict:
    """Post the `/opencode` comment — carrying the adversarial brief — that
    fires the reviewer workflow.

    [LAW:no-silent-failure] confirm GitHub accepted the comment; a dropped
    trigger would leave wait() polling for a run that never starts."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    proc = subprocess.run(
        ["gh", "pr", "comment", str(pr_num), "--repo", f"{owner}/{repo}",
         "--body", _trigger_body()],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to post the /opencode trigger comment on {pr_url}: "
            f"{proc.stderr.strip()[:500]}"
        )
    return {"triggered": True, "comment_url": proc.stdout.strip() or None}


def _latest_trigger_ts(owner: str, repo: str, pr_num: int) -> str:
    """ISO8601 timestamp of the newest /opencode (or /oc) comment on the PR.

    Both PR issue comments and inline review comments can carry the trigger
    (the workflow listens on issue_comment AND pull_request_review_comment), so
    both streams are scanned. [LAW:no-silent-failure] no trigger comment means
    no review was ever requested — that must halt, not read as done."""
    issue = _gh_json(
        "api", f"repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {body, created_at: .created_at}]",
    ) or []
    review = _gh_json(
        "api", f"repos/{owner}/{repo}/pulls/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {body, created_at: .created_at}]",
    ) or []
    stamps = [c["created_at"] for c in (*issue, *review) if _is_trigger(c.get("body", ""))]
    if not stamps:
        raise RuntimeError(
            f"No /opencode trigger comment found on {owner}/{repo}#{pr_num} — "
            "call provider.trigger(pr_url) first; this provider fires on the "
            "comment, not on push."
        )
    return max(stamps)  # ISO8601 UTC sorts lexicographically


def _opencode_runs_since(owner: str, repo: str, since_ts: str) -> list[dict]:
    """opencode workflow runs created at/after since_ts, newest first."""
    runs = _gh_json(
        "api", f"repos/{owner}/{repo}/actions/workflows/{WORKFLOW_FILE}/runs?per_page=30",
        "--jq", "[.workflow_runs[] | {id, status, conclusion, created_at, html_url}]",
    ) or []
    fresh = [r for r in runs if r["created_at"] >= since_ts]
    return sorted(fresh, key=lambda r: r["created_at"], reverse=True)


def wait(pr_url: str) -> dict:
    """Block until the opencode review fired by the newest trigger comment
    completes, then return its outcome.

    The run is correlated to its triggering comment, not to a head SHA (an
    issue-comment run reports the default branch as head). [LAW:no-silent-
    failure] a non-success conclusion means the reviewer itself errored — its
    findings are absent, not empty; the caller surfaces the url and stops."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    since = _latest_trigger_ts(owner, repo, pr_num)
    pr_head = github_threads.head_sha(owner, repo, pr_num)

    deadline = time.monotonic() + WAIT_TIMEOUT_S
    while time.monotonic() < deadline:
        runs = _opencode_runs_since(owner, repo, since)
        if runs:
            run = runs[0]
            if run["status"] == "completed":
                return {
                    "status": "completed",
                    "conclusion": run.get("conclusion") or "unknown",
                    "sha": pr_head,
                    "url": run.get("html_url"),
                }
        # No run yet (CI hasn't created it) or it's queued/in_progress — keep
        # polling. Both cases are normal early in the loop.
        time.sleep(POLL_INTERVAL_S)

    raise RuntimeError(
        f"Timed out after {WAIT_TIMEOUT_S}s waiting for an opencode run created "
        f"since {since} on {owner}/{repo}#{pr_num}. The reviewer may not have "
        "started — check Actions; do not treat this as a clean review."
    )


def _latest_review_comment(owner: str, repo: str, pr_num: int, since_ts: str):
    """The opencode verdict: `(n, comment)` for the newest non-trigger PR issue
    comment created at/after since_ts whose body carries `REVIEW_COMPLETE: <N>`,
    or None when no such comment exists.

    Keyed on the contract trailer, not on the reviewer's bot login, so a renamed
    reviewer account can't silently drop the signal. [LAW:one-source-of-truth]
    Trigger comments are excluded — the brief they carry quotes the literal
    `REVIEW_COMPLETE: <N>` (no digit), and excluding them also stops a future
    trigger body from being misread as a verdict."""
    comments = _gh_json(
        "api", f"repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {author: .user.login, body, created_at}]",
    ) or []
    best = None  # (created_at, n, comment)
    for c in comments:
        if c["created_at"] < since_ts or _is_trigger(c.get("body", "")):
            continue
        m = REVIEW_COMPLETE_RE.search(c.get("body") or "")
        if not m:
            continue
        if best is None or c["created_at"] > best[0]:
            best = (c["created_at"], int(m.group(1)), c)
    if best is None:
        return None
    return best[1], best[2]


def fetch(pr_url: str) -> dict:
    """Return opencode's pending findings for the current review in canonical
    form. opencode reports concerns within a single summary comment whose last
    line is `REVIEW_COMPLETE: <N>`; that comment — not inline review threads —
    is the source of truth.

    [LAW:verifiable-goals] `N == 0` is the one signal that establishes 'clean':
    it yields an empty finding list, which is what ends the skill's loop. While
    `N > 0`, the whole verdict comment is surfaced as a single unresolved
    finding carrying every concern in its body — the author addresses them,
    re-triggers, and the next review's N is the convergence signal.

    [LAW:no-silent-failure] a completed review that posted no `REVIEW_COMPLETE`
    trailer is a missing verdict, not a clean pass — it halts."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    since = _latest_trigger_ts(owner, repo, pr_num)
    verdict = _latest_review_comment(owner, repo, pr_num, since)
    if verdict is None:
        raise RuntimeError(
            f"opencode posted no REVIEW_COMPLETE verdict on {owner}/{repo}#{pr_num} "
            f"since {since}. The review did not emit its contract trailer — do "
            "not treat this as a clean, zero-finding pass; check the Actions run."
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

    parser = argparse.ArgumentParser(description="opencode PR review provider (direct)")
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
