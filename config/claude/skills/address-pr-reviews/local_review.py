#!/usr/bin/env python3
"""Shared engine for LOCAL PR-review providers — the model-agnostic machinery
every "run the adversarial review on this machine and post the verdict" provider
needs, with the one thing that genuinely varies factored out into a `Runner`.

Two providers ride this engine: `claude_provider` (Sonnet on the Claude Code
subscription) and `grok_provider` (grok-4.5 on the xAI subscription via the
`opencode` CLI). They are behaviorally identical to the skill — same
CAPABILITIES, same canonical finding shape, same convergence on the
`REVIEW_COMPLETE: <N>` trailer (resolve unsupported: the verdict is a PR issue
comment, not a resolvable thread). Switch between them by editing one value in
`provider.json`.

[LAW:one-source-of-truth] the review *criteria* are the single shared brief in
`opencode_trigger_prompt.md` — every local reviewer judges the diff by the
identical rules, so switching provider changes the model, never the bar. The
*plumbing* (resolve the repo root, gather the diff + prior discussion, validate
the trailer, post the comment, read the verdict back) is this one module, so a
fix to any of it moves both reviewers together. The ONLY thing a provider
supplies is a `Runner`: the exact seam where "which model, invoked how" lives.

[LAW:effects-at-boundaries] the pure step — the model computing the review — is
isolated behind `Runner.run`: this engine gathers inputs (diff, PR context) at
the boundary, hands them to the runner as data, validates the returned text, and
performs the one write (posting the comment) at the boundary. A runner reads the
repo read-only and returns text; it never posts or edits.

[LAW:no-silent-failure] a runner that fails, a review with no `REVIEW_COMPLETE`
trailer, or a `gh` post that fails — each halts loudly. A missing verdict is
never read as a clean, zero-finding pass.

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
from dataclasses import dataclass
from pathlib import Path
from typing import Callable

import github_threads

# The shared adversarial brief. [LAW:one-source-of-truth] reused from the
# opencode trigger prompt (minus its leading /opencode trigger token) so every
# local reviewer holds the diff to the identical bar; edit it once, all move.
BRIEF_FILE = Path(__file__).parent / "opencode_trigger_prompt.md"

_TRIGGER_PREFIXES = ("/opencode", "/oc")

# A LOCAL reviewer's law of record. It does NOT inline the laws; it tells the
# reviewer to LOAD the one law-set matching each changed file's medium, exactly
# the way the human's own laws router works: both runtimes this engine drives
# already inject a per-medium routing menu and a laws loader every turn — opencode
# via the `laws-router.js` plugin (the `laws_*` tools), Claude Code via the
# `skill-router.sh` hook (`Skill(laws:*)`). [LAW:one-source-of-truth] the loader
# reads the SAME canonical vendored files the `laws:*` skills read, on demand, so
# there is no per-repo philosophy file to sync and no second copy pasted here.
# [LAW:no-silent-failure] "load the laws before you judge" is mandated, with the
# negative example spelled out, so a reviewer cannot silently grade from memory.
_LOCAL_LAW_OF_RECORD = (
    "## Your law of record\n\n"
    "Ground every finding in the engineering laws — the universal architectural "
    "laws and their per-medium law-sets (code, prose, prompt, ticket). Your "
    "environment has already given you a routing menu and a laws loader: in "
    "opencode, the `laws_code` / `laws_prose` / `laws_prompt` / `laws_ticket` "
    "tools; in Claude Code, `Skill(laws:code|prose|prompt|ticket)`.\n\n"
    "Before you judge a changed file, LOAD the ONE law-set matching that file's "
    "medium and judge it by that law-set — code files (source, tests, schemas, "
    "configs, scripts) by the CODE laws; a README or human doc by the PROSE laws; "
    "a `CLAUDE.md`, skill body, or system-prompt file by the PROMPT laws. Load "
    "only the media the diff actually touches — usually just code, sometimes code "
    "and prose; never all four for a code diff. Do NOT stack media (code's "
    "terseness is not a defect in prose; prose's redundancy is not rigor in code).\n\n"
    "Do NOT review from memory: a review that loaded no law-set has no bar, and a "
    "finding you cannot tie to a loaded `[LAW:<token>]` is not a finding. Cite the "
    "exact `[LAW:<token>]` the matching law-set defines."
)

# The contract trailer — the single machine-verifiable verdict, identical to the
# CI opencode provider's, so every provider converges on the same signal.
REVIEW_COMPLETE_RE = re.compile(r"REVIEW_COMPLETE:\s*(\d+)")

# How a local model delivers its review. The shared brief's output contract says
# "post a summary comment"; a local model does not post — the harness does. This
# is appended to the brief so the criteria stay shared and only delivery
# diverges. Deliberately names no specific tool (each runner's read-only surface
# has its own tool names), only the capability: read, don't write.
_DELIVERY_ADAPTER = (
    "---\n"
    "DELIVERY — how this review is collected: You are a LOCAL reviewer with "
    "READ-ONLY access to the repository — you can read and search files for "
    "context (callers, schemas, tests) but you cannot write files, run shell "
    "commands, or fetch the web. Do NOT attempt to post comments or open review "
    "threads — the harness posts your review for you. Produce your ENTIRE review "
    "as your final message, without narrating intermediate steps. Per the output "
    "contract above, its LAST line MUST be exactly `REVIEW_COMPLETE: <N>`. Your "
    "message is posted to the PR verbatim."
)


@dataclass(frozen=True)
class Runner:
    """The one seam a local provider supplies: which model, invoked how.

    [LAW:types-are-the-program] everything a local reviewer varies is exactly
    these four fields — the binary to preflight, two human-readable strings, and
    the pure `run` that turns (prompt, brief, cwd) into the review text. Nothing
    else about a local reviewer differs, so nothing else is representable here.

    `run(prompt, brief, cwd) -> str` executes the model read-only in `cwd`,
    combining `brief` (the shared criteria) with `prompt` (this PR's diff +
    context) however that model wants them, and returns the review text. It owns
    its own exit-code/timeout handling and raises `RuntimeError` on failure; the
    engine owns the trailer check that applies to every runner alike."""

    cli: str                                    # binary preflighted on PATH
    describe: str                               # setup_check success label
    marker: str                                 # the triggered-marker comment body
    run: Callable[[str, str, str], str]         # (prompt, brief, cwd) -> review text


CAPABILITIES = {
    "resolve":     False,  # the verdict is a PR issue comment, not a resolvable thread
    "trigger":     True,   # the review runs only when explicitly invoked
    "setup_check": True,   # verifies the runner's CLI + gh are usable
}


def _gh_json(*args: str):
    out = github_threads.gh(*args)
    return json.loads(out) if out else None


def review_brief() -> str:
    """The adversarial review brief for a local model: the shared criteria from
    the opencode brief, the load-on-demand law of record (the reviewer loads the
    matching medium's laws via its runtime's laws router), and the delivery
    instruction adapted (the model outputs its review; it does not post it).

    [LAW:no-silent-failure] a missing brief would leave the reviewer with no
    criteria and silently diverge from the shared bar — fail loud instead."""
    if not BRIEF_FILE.exists():
        raise RuntimeError(
            f"review brief missing: {BRIEF_FILE}. Without it a local reviewer "
            "has no criteria and would not match the shared reviewer bar."
        )
    brief = BRIEF_FILE.read_text().strip()
    for p in _TRIGGER_PREFIXES:
        if brief.startswith(p):
            brief = brief[len(p):].lstrip()
            break
    return f"{brief}\n\n{_LOCAL_LAW_OF_RECORD}\n\n{_DELIVERY_ADAPTER}"


def setup_check(owner: str, repo: str, runner: Runner) -> dict:
    """Verify the local reviewer's prerequisites: the runner's CLI, an
    authenticated gh, and the shared brief. [LAW:no-silent-failure] a missing
    tool is a hard stop, never an empty clean pass."""
    if not shutil.which(runner.cli):
        return {"installed": False,
                "message": f"`{runner.cli}` CLI is not on PATH — install it first."}
    if not shutil.which("gh"):
        return {"installed": False, "message": "`gh` is not on PATH — install it first."}
    auth = subprocess.run(["gh", "auth", "status"], capture_output=True, text=True)
    if auth.returncode != 0:
        return {"installed": False,
                "message": f"gh is not authenticated: {auth.stderr.strip()[:500]}"}
    if not BRIEF_FILE.exists():
        return {"installed": False, "message": f"review brief missing: {BRIEF_FILE}"}
    return {"installed": True, "message": f"{runner.describe} + gh ready for {owner}/{repo}"}


def _remote_slug(path: str) -> str | None:
    """The `owner/repo` slug of `path`'s origin remote, lowercased, or None when
    `path` is not a git repo with an origin remote. Used to confirm a candidate
    review root is the PR's repository — not whatever repo the process CWD landed
    in. This skill is symlinked from a *different* repo, so an ambient
    `git rev-parse` run from the skill dir resolves to that repo, not the PR's."""
    proc = subprocess.run(
        ["git", "-C", path, "remote", "get-url", "origin"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None
    m = re.search(r"[:/]([^/]+/[^/]+?)(?:\.git)?/?$", proc.stdout.strip())
    return m.group(1).lower() if m else None


def _pr_head_branch(owner: str, repo: str, pr_num: int) -> str | None:
    raw = github_threads.gh(
        "pr", "view", str(pr_num), "--repo", f"{owner}/{repo}",
        "--json", "headRefName",
    )
    try:
        return json.loads(raw).get("headRefName") if raw else None
    except json.JSONDecodeError:
        return None


def _branch_worktree(repo_path: str, head_branch: str | None) -> str | None:
    """The worktree under `repo_path` checked out to the PR's head branch, if any
    — so the reviewer reads the exact code under review rather than whichever
    branch the chosen root happens to sit on. None when it can't be determined."""
    if not head_branch:
        return None
    proc = subprocess.run(
        ["git", "-C", repo_path, "worktree", "list", "--porcelain"],
        capture_output=True, text=True,
    )
    if proc.returncode != 0:
        return None
    current = None
    for line in proc.stdout.splitlines():
        if line.startswith("worktree "):
            current = line[len("worktree "):]
        elif line.startswith("branch ") and current:
            if line[len("branch "):] == f"refs/heads/{head_branch}":
                return current
    return None


def _repo_root(owner: str, repo: str, pr_num: int) -> str:
    """The repository directory the runner reads for surrounding context, resolved
    to the PR's *actual* repository and validated — never blindly the ambient
    CWD's repo.

    [LAW:no-ambient-temporal-coupling] the review root must be the PR's repo, not
    whatever repo the process is standing in. This skill is symlinked from a
    different repo, so an ambient `git rev-parse` from the skill dir resolves to
    that repo; the reviewer would then find none of the PR's files.

    [LAW:no-silent-failure] a candidate whose origin remote is not the PR's repo
    is a hard stop with an actionable message — never a quiet diff-only review
    (the exact failure this replaces: the model announcing "the repository is not
    accessible locally" and grading the diff alone).

    Precedence: explicit `PR_REVIEW_REPO_ROOT` env > the git worktree at CWD.
    Whichever is chosen must be the PR's repo; if it has a worktree checked out
    to the PR's head branch, that worktree is preferred."""
    want = f"{owner}/{repo}".lower()
    env_root = os.environ.get("PR_REVIEW_REPO_ROOT")
    if env_root:
        candidate = env_root
    else:
        proc = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True
        )
        candidate = proc.stdout.strip() if proc.returncode == 0 else ""
    if not candidate:
        raise RuntimeError(
            f"Cannot locate the {owner}/{repo} checkout for the local review: not "
            "inside a git worktree and PR_REVIEW_REPO_ROOT is unset. Run the skill "
            f"from the PR's worktree, or set PR_REVIEW_REPO_ROOT to a {owner}/{repo} "
            "checkout."
        )
    slug = _remote_slug(candidate)
    if slug != want:
        raise RuntimeError(
            f"Local review root {candidate!r} is the {slug or 'non-git'} repo, not "
            f"{owner}/{repo}. The reviewer would find none of the PR's files and "
            "silently grade the diff alone. Run the skill from the PR's worktree, "
            f"or set PR_REVIEW_REPO_ROOT to a {owner}/{repo} checkout."
        )
    return _branch_worktree(candidate, _pr_head_branch(owner, repo, pr_num)) or candidate


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


def build_prompt(owner: str, repo: str, pr_num: int) -> str:
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


def _run_review(owner: str, repo: str, pr_num: int, runner: Runner) -> str:
    """Run the local review via the runner and return its text, validated to
    carry the `REVIEW_COMPLETE` trailer. Pure compute: reads, never writes.

    [LAW:single-enforcer] the trailer check lives here, once, for every runner —
    a runner owns only its own exit/timeout handling; the verdict contract that
    is identical across all local reviewers is enforced in exactly one place."""
    prompt = build_prompt(owner, repo, pr_num)
    cwd = _repo_root(owner, repo, pr_num)
    review = runner.run(prompt, review_brief(), cwd).strip()
    if not REVIEW_COMPLETE_RE.search(review):
        raise RuntimeError(
            f"{runner.cli} review produced no `REVIEW_COMPLETE: <N>` trailer — the "
            "verdict is missing, not clean; do not treat this as a clean review."
        )
    return review


def _post_comment(owner: str, repo: str, pr_num: int, body: str,
                  pr_url: str, what: str) -> str | None:
    """Post one PR comment, confirming GitHub accepted it. [LAW:single-enforcer]
    every comment a local provider writes goes through here. [LAW:no-silent-
    failure] a dropped post raises, never returns quietly."""
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


def trigger(pr_url: str, runner: Runner) -> dict:
    """Post a visible 'triggered' marker, run the local review, then post its
    verdict as a PR comment.

    The marker makes the trigger observable on the PR the moment a review is
    requested — before the local review (minutes) finishes — mirroring the
    visible /opencode trigger comment. It carries no `REVIEW_COMPLETE` trailer,
    so fetch() never mistakes it for the verdict."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    _post_comment(owner, repo, pr_num, runner.marker, pr_url, "trigger marker")
    review = _run_review(owner, repo, pr_num, runner)
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


def cli_main(module) -> None:
    """Shared CLI shim for a local-review provider module — direct invocation for
    testing and ad-hoc runs. [LAW:one-source-of-truth] every local provider's
    command-line surface is this one dispatcher, bound to the module's public
    functions, so `python3 <name>_provider.py trigger <url>` behaves identically
    across providers."""
    import argparse

    parser = argparse.ArgumentParser(description=f"{module.__name__} (direct)")
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
            out = module.setup_check(args.owner, args.repo)
        else:
            out = getattr(module, args.command)(args.pr_url)
        print(json.dumps(out, indent=2))
    except subprocess.CalledProcessError as e:
        msg = (e.stderr or "").strip() or str(e)
        print(f"ERROR ({args.command}): {msg}", file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, ValueError) as e:
        print(f"ERROR ({args.command}): {e}", file=sys.stderr)
        sys.exit(1)
