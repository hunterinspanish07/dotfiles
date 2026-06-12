#!/usr/bin/env python3
"""opencode PR review provider — drives the repo's `opencode` GitHub Actions
reviewer (`.github/workflows/opencode.yml`, the `anomalyco/opencode/github`
action) and reads its findings as ordinary GitHub review threads.

[LAW:effects-at-boundaries] this module only acts: it posts the `/opencode`
trigger comment and polls the Actions API. The review itself runs remotely in
CI; nothing here computes findings.

[LAW:one-source-of-truth] opencode posts inline findings as
`pull_request_review_comment`s — i.e. ordinary resolvable review threads — so
`fetch`/`resolve` are reused verbatim from `github_threads`; this module never
mints a second reader.

Correlation is stateless and survives a process boundary: the workflow fires on
an `issue_comment` containing `/opencode` (or `/oc`), and an issue-comment run's
own `head_sha` is the default branch, never the PR head. So `wait` cannot key on
run head SHA. Instead it keys on the **triggering comment** — the newest
`/opencode` comment on the PR is the authoritative "when this review was
requested", and the matching run is the first opencode run created at/after it.
[LAW:no-shared-mutable-globals] no module state passes trigger -> wait.
"""

from __future__ import annotations

import json
import subprocess
import sys
import time

import github_threads
from github_threads import fetch, resolve  # noqa: F401  (contract surface)

CAPABILITIES = {
    "resolve":     True,   # findings are GitHub review threads
    "trigger":     True,   # the reviewer runs only when /opencode is posted
    "setup_check": True,   # verifies gh + the opencode workflow is installed
}

# The workflow file that defines the reviewer. setup_check and wait both key
# off this one name. [LAW:one-source-of-truth]
WORKFLOW_FILE = "opencode.yml"

# Bodies that fire the workflow, per opencode.yml's `if:` condition.
TRIGGER_BODY = "/opencode"
_TRIGGER_PREFIXES = ("/opencode", "/oc")

# Poll cadence and ceiling for wait(). A CI review of a normal diff finishes
# well inside this; exceeding it is a hard failure, never a silent clean pass.
POLL_INTERVAL_S = 10
WAIT_TIMEOUT_S = 1800


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
    return {"installed": True, "message": f"gh ready; {WORKFLOW_FILE} active in {owner}/{repo}"}


def trigger(pr_url: str) -> dict:
    """Post the `/opencode` comment that fires the reviewer workflow.

    [LAW:no-silent-failure] confirm GitHub accepted the comment; a dropped
    trigger would leave wait() polling for a run that never starts."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    proc = subprocess.run(
        ["gh", "pr", "comment", str(pr_num), "--repo", f"{owner}/{repo}",
         "--body", TRIGGER_BODY],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"Failed to post '{TRIGGER_BODY}' trigger comment on {pr_url}: "
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
    p_resolve = sub.add_parser("resolve")
    p_resolve.add_argument("thread_id")
    p_setup = sub.add_parser("setup_check")
    p_setup.add_argument("owner")
    p_setup.add_argument("repo")

    args = parser.parse_args()
    try:
        if args.command == "resolve":
            out = resolve(args.thread_id)
        elif args.command == "setup_check":
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
