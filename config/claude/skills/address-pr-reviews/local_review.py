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
the newest verdict stamped with this runner's model, which — because `trigger`
just posted it with the same runner — is always the current review.

Every pass reviews everything since a BASELINE, and the baseline is a value (see
`Baseline`), not a mode. On a PR this model has not reviewed the baseline is the
merge-base, so the model sees the whole diff. On a follow-up the baseline is the
commit this model's last verdict judged — recorded in the stamp on that verdict
comment, so the PR itself is the only place the baseline lives — and the model
sees its own standing findings plus the fixups, instead of the entire PR re-sent
at full price for a three-line change. [LAW:dataflow-not-control-flow] first
pass and follow-up run the identical code with different values in it; there is
no incremental mode to turn on and no flag to get wrong.
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

# The contract trailer — the model's finding COUNT, identical to the CI
# opencode provider's, so every provider converges on the same signal. It
# supplies the count ONLY; whether a comment is a verdict at all is answered by
# the engine's verdict stamp below, never by this prose — a human can quote it.
REVIEW_COMPLETE_RE = re.compile(r"REVIEW_COMPLETE:\s*(\d+)")

# The two machine-readable stamps the ENGINE writes onto its own comments, as
# HTML comments (invisible in GitHub's rendered view).
#
# `MARKER_TOKEN` tags a trigger marker so the next pass can drop it from the
# prompt. Keying on this token rather than on the marker's prose is what makes
# the filter hold across providers: a Runner supplies marker *wording*, never
# the contract. [LAW:one-source-of-truth]
#
# The VERDICT stamp is the single home of verdict identity: *that* a comment is
# an engine verdict, *which model* produced it, and *which commit* it judged —
# one stamp, because two would make "model without sha" and "sha without model"
# representable, and neither is a real state. Its presence — not the
# `REVIEW_COMPLETE` trailer, which is the MODEL's contract and therefore prose
# a human can legitimately quote — is what answers "is this comment a verdict";
# the trailer survives only to supply the count. [LAW:one-source-of-truth] the
# model key scopes a verdict to the configuration that produced it, so one
# reviewer's verdict is never another reviewer's baseline, and the sha makes
# the PR itself the single home of the review baseline — no local state file,
# nothing to desync, and a fresh context or a different machine reads the same
# answer. The engine stamps both facts because the engine is what computed
# them; asking the model to echo either back would be a second, drift-prone
# map of a fact the caller already holds. [FRAMING:representation]
MARKER_TOKEN = "<!-- pr-review:marker -->"
VERDICT_RE = re.compile(
    r'<!--\s*pr-review:verdict\s+model="([^"]+)"\s+sha="([0-9a-f]{7,40})"\s*-->'
)


def _verdict_stamp(model: str, sha: str) -> str:
    return f'<!-- pr-review:verdict model="{model}" sha="{sha}" -->'


def _trailer(review: str):
    """The contract trailer: the LAST `REVIEW_COMPLETE: <N>` match in the text.
    The delivery contract pins the trailer as the final line, so an earlier
    match is prose — the model quoting an earlier pass's count, or the brief's
    own instruction — not the verdict. The stamp's insertion point and the
    count that is read back both key on this last match: keying on the first
    would strand the stamp mid-prose beside a quoted count and then report
    that quoted count as the verdict. [LAW:one-source-of-truth]"""
    matches = list(REVIEW_COMPLETE_RE.finditer(review))
    return matches[-1] if matches else None

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
    these five fields — the machine key naming the reviewing configuration, the
    binary to preflight, two human-readable strings, and the pure `run` that
    turns (prompt, brief, cwd) into the review text. Nothing else about a local
    reviewer differs, so nothing else is representable here.

    `model` is the machine identity of the reviewing configuration, stamped on
    every verdict this runner produces and matched when one is read back. The
    other fields cannot supply it: `cli` is "opencode" for three different
    reviewers, and `describe` and `marker` are human prose — which this file
    already refuses to treat as contract anywhere else, and does not start to
    here.

    `run(prompt, brief, cwd) -> str` executes the model read-only in `cwd`,
    combining `brief` (the shared criteria) with `prompt` (this PR's diff +
    context) however that model wants them, and returns the review text. It owns
    its own exit-code/timeout handling and raises `RuntimeError` on failure; the
    engine owns the trailer check that applies to every runner alike."""

    model: str                                  # machine key naming the reviewing configuration, for the stamp
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


def _pr_field(owner: str, repo: str, pr_num: int, field: str) -> str | None:
    """One scalar field off the PR, or None when it can't be read.
    [LAW:one-type-per-behavior] `headRefName` and `baseRefName` are the same
    read with a different value in it, not two functions."""
    raw = github_threads.gh(
        "pr", "view", str(pr_num), "--repo", f"{owner}/{repo}", "--json", field,
    )
    try:
        return json.loads(raw).get(field) if raw else None
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
    head_branch = _pr_field(owner, repo, pr_num, "headRefName")
    return _branch_worktree(candidate, head_branch) or candidate


def _git(root: str, *args: str) -> str:
    """One git call in the review root. [LAW:single-enforcer] every git shell-out
    the engine makes goes through here. [LAW:no-silent-failure] a nonzero exit
    raises with git's own stderr rather than yielding an empty string that would
    read downstream as 'nothing changed'."""
    proc = subprocess.run(
        ["git", "-C", root, *args], capture_output=True, text=True,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"`git {' '.join(args)}` failed in {root}: {proc.stderr.strip()[:500]}"
        )
    return proc.stdout


def _have(root: str, rev: str) -> bool:
    return subprocess.run(
        ["git", "-C", root, "rev-parse", "--verify", "--quiet", f"{rev}^{{commit}}"],
        capture_output=True,
    ).returncode == 0


def _resolve(root: str, rev: str) -> str:
    """`rev` as a concrete commit sha, fetching once if the object isn't local
    yet (a worktree can legitimately be behind the PR's head or its base).

    [LAW:no-silent-failure] a rev that is still unresolvable after the fetch is a
    hard stop with an actionable message — never a silent fall back to a wider or
    narrower diff, which would change what the reviewer is judging without
    anyone being told."""
    if not _have(root, rev):
        subprocess.run(["git", "-C", root, "fetch", "origin"], capture_output=True)
    if not _have(root, rev):
        raise RuntimeError(
            f"Cannot resolve {rev!r} in {root} even after `git fetch origin` — the "
            "review baseline is unknown, so the diff under review cannot be "
            "computed. Check that the worktree tracks the PR's remote."
        )
    return _git(root, "rev-parse", f"{rev}^{{commit}}").strip()


@dataclass(frozen=True)
class Baseline:
    """What this review pass is measured against.

    [LAW:one-type-per-behavior] a first pass and a follow-up pass are not two
    kinds of review — they are this one type holding different values, so the
    engine below has one code path and no mode:

      cold  — `sha` is the merge-base with the PR's base branch, `standing` is
              empty, `since` is empty. The diff is the whole PR.
      warm  — `sha` is the commit the last verdict judged, `standing` is that
              verdict's TEXT with the engine's stamp stripped out, `since` is
              when it posted. The diff is the fixups.

    `standing` carries findings, never bookkeeping. The stamp is stripped at the
    boundary that builds this value because `standing` is quoted back to the
    model in the prompt: a stamp the model can see is a stamp the model can
    echo, and an echoed stamp in the posted verdict is a second, older answer to
    "which commit did this judge" sitting ahead of the real one in the same
    comment. Removing it here makes that unrepresentable rather than defended
    against downstream. [LAW:types-are-the-program] [LAW:one-source-of-truth]

    [LAW:dataflow-not-control-flow] `standing` and `since` are empty strings on a
    cold pass rather than None, because the empty string is the identity value
    for both consumers: nothing to carry forward, and `created_at > ""` is true
    for every comment. That is what lets the caller skip the `if first_pass`
    branch entirely — the values differ, the operations do not."""

    sha: str
    standing: str
    since: str


def _baseline(owner: str, repo: str, pr_num: int, root: str, head: str,
              model: str) -> Baseline:
    """Resolve this pass's baseline from the PR itself. [LAW:one-source-of-truth]
    the verdict stamp on the newest verdict comment naming THIS model is the
    only record of what has been reviewed; there is no local state file to fall
    out of sync with it. The model key is load-bearing: a verdict from a
    different model is not this model's baseline, so one reviewer's verdict can
    never stand in for another's — a cheaper reviewer's clean pass must not
    block a stronger one from ever running.

    [LAW:no-defensive-null-guards] the optionality of "is there a prior verdict
    for this model, and is its commit reachable" is resolved once, here at the
    trust boundary, and every caller downstream gets a total `Baseline`.

    An unmatched prior verdict — unstamped, carrying a stamp format this engine
    retired, or from another model — or an unreachable one yields the cold
    baseline: the full PR diff, re-reviewed once. [LAW:no-silent-failure] that
    is the conservative direction — always err toward running a review, never
    toward skipping one — and the one-time cost of retiring a stamp format,
    accepted up front."""
    verdict = _latest_review_comment(owner, repo, pr_num, model)
    stamp = VERDICT_RE.search(verdict[1].get("body") or "") if verdict else None
    if stamp and _have(root, stamp.group(2)):
        comment = verdict[1]
        return Baseline(
            sha=_resolve(root, stamp.group(2)),
            standing=VERDICT_RE.sub("", comment.get("body") or "").strip(),
            since=comment.get("created_at") or "",
        )
    base_branch = _pr_field(owner, repo, pr_num, "baseRefName")
    if not base_branch:
        raise RuntimeError(
            f"Cannot read the base branch of {owner}/{repo}#{pr_num} — the review "
            "baseline is unknown; refusing to guess the diff under review."
        )
    base = _resolve(root, f"origin/{base_branch}")
    return Baseline(sha=_git(root, "merge-base", base, head).strip(),
                    standing="", since="")


def _human_replies(owner: str, repo: str, pr_num: int, since: str) -> str:
    """PR discussion the reviewer has not already seen: comments posted after
    `since`, minus the engine's own exhaust.

    Two classes of comment are dropped because feeding them back costs tokens and
    actively degrades the review. A trigger MARKER carries no information at all.
    A superseded VERDICT is worse than noise: it lists findings that have since
    been fixed, and a reviewer reading them re-raises settled concerns. That
    drop is deliberately NOT model-scoped — a superseded verdict from ANY model
    is that noise, so all of them go. The verdict that still matters — this
    model's newest — reaches the model as `Baseline.standing`, once.
    [LAW:one-source-of-truth]

    Filtering keys on the engine's own machine-readable stamps, never on prose —
    not on marker wording, and not on the `REVIEW_COMPLETE` trailer, which is
    the model's contract and therefore text a HUMAN can legitimately quote. A
    human comment quoting the trailer is a reply the reviewer must see;
    matching prose here is what silently swallowed one. [LAW:no-silent-failure]

    One bounded gap: markers posted before `MARKER_TOKEN` existed carry no
    token, and verdict-shaped comments this engine did not stamp — the CI
    opencode provider's trailer-only verdicts, or a retired local stamp
    format — are no longer recognized here. A warm pass drops them anyway
    (they predate `since`), but a cold pass on such a PR still carries them
    once. Matching the old prose instead would trade a permanent fragile match
    — one that eats human replies quoting it — for a shrinking historical
    cost, so it is left alone."""
    issue = _gh_json(
        "api", f"repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {author: .user.login, body, created_at}]",
    ) or []
    review = _gh_json(
        "api", f"repos/{owner}/{repo}/pulls/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {author: .user.login, body, created_at}]",
    ) or []
    lines = []
    for c in (*issue, *review):
        body = (c.get("body") or "").strip()
        if not body or (c.get("created_at") or "") <= since:
            continue
        if MARKER_TOKEN in body or VERDICT_RE.search(body):
            continue
        lines.append(f"@{c['author']}: {body[:4000]}")
    return "\n\n".join(lines)


def build_prompt(owner: str, repo: str, pr_num: int, root: str,
                 baseline: Baseline, head: str) -> str:
    """The review input handed to the model: PR metadata, the findings still
    standing from the last pass, discussion since then, and the diff since the
    baseline commit.

    [LAW:one-source-of-truth] the diff is always `git diff baseline..head` — one
    mechanism for "what changed since the baseline", whether the baseline is the
    merge-base (whole PR) or the last reviewed commit (the fixups). Deriving the
    cold diff from `gh pr diff` and the warm one from git would be two maps of
    one fact, free to disagree about the merge-base.

    [LAW:no-silent-failure] an empty diff on a COLD pass is an error — nothing to
    review, or the PR is inaccessible. On a warm pass it is a fact, not a fault:
    the author pushed no code and is answering the review in prose, which the
    caller has already established is worth a pass."""
    meta_raw = github_threads.gh(
        "pr", "view", str(pr_num), "--repo", f"{owner}/{repo}", "--json", "title,body",
    )
    meta = json.loads(meta_raw) if meta_raw else {}

    diff = _git(root, "diff", f"{baseline.sha}..{head}")
    if not diff.strip() and not baseline.standing:
        raise RuntimeError(
            f"`git diff {baseline.sha[:8]}..{head[:8]}` is empty for "
            f"{owner}/{repo}#{pr_num} — nothing to review, or the PR/diff is "
            "inaccessible."
        )

    replies = _human_replies(owner, repo, pr_num, baseline.since)
    parts = [
        f"Review pull request {owner}/{repo}#{pr_num} adversarially, per your "
        "system instructions.",
        f"Title: {meta.get('title', '')}",
        f"Description:\n{meta.get('body') or '(none)'}",
    ]
    if baseline.standing:
        # A follow-up pass. The standing verdict IS the carried-forward finding
        # list, and the contract below is what keeps `REVIEW_COMPLETE: <N>`
        # meaning "concerns still open on this PR" rather than "concerns new
        # since the last pass" — without it, a fixup pass that finds nothing new
        # would report 0 and end the author's loop with the first pass's findings
        # unaddressed. [LAW:verifiable-goals]
        parts.append(
            "You have ALREADY reviewed this PR. Your previous verdict, in full, is "
            f"below. The author has since pushed the changes in the diff.\n\n"
            f"--- YOUR PREVIOUS VERDICT ---\n{baseline.standing}\n--- END ---"
        )
        parts.append(
            "This pass judges TWO things:\n"
            "1. Each concern from your previous verdict: is it now actually fixed? "
            "Read the current file at each cited location to check — do not assume "
            "the diff below tells the whole story.\n"
            "2. The new changes in the diff: do they introduce any new defect, "
            "including breaking something the diff does not touch?\n\n"
            "CRITICAL — the count in your trailer is the number of concerns STILL "
            "OPEN on this PR: every previous concern you judge unfixed, PLUS every "
            "new one. Restate each still-open concern (you may keep it brief and "
            "reference your earlier wording); list each fixed one as resolved and "
            "do NOT count it. `REVIEW_COMPLETE: 0` means the whole PR is clean, "
            "never merely that this fixup added nothing new.\n\n"
            "Do not re-raise a concern you previously listed and the author "
            "rebutted in the discussion below."
        )
    if replies:
        parts.append(
            "New discussion since your last verdict — do NOT re-raise concerns "
            f"settled here:\n{replies}"
        )
    parts.append(
        "You may read any file in the repository for surrounding context "
        "(callers, schemas, tests) before judging. The diff below is the change "
        "under review, not the limit of what you may read."
    )
    label = (
        f"Changes since your last review ({baseline.sha[:8]}..{head[:8]})"
        if baseline.standing else "Diff under review"
    )
    parts.append(f"{label}:\n```diff\n{diff}\n```")
    return "\n\n".join(parts)


def _stamp(review: str, model: str, sha: str) -> str:
    """Record which model produced this verdict and which commit it judged,
    immediately above the trailer so `REVIEW_COMPLETE: <N>` stays the last line
    the contract promises it is.

    [LAW:one-source-of-truth] this one stamp is the single home of verdict
    identity — verdict-ness, producer, and judged commit — and what makes the PR
    itself the record the next pass reads back in `_baseline` and `fetch`.
    Insertion keys on the trailer match, never on a prose quote of it."""
    line = _trailer(review)
    head, tail = review[:line.start()].rstrip(), review[line.start():]
    return f"{head}\n\n{_verdict_stamp(model, sha)}\n\n{tail}"


def _run_review(owner: str, repo: str, pr_num: int, runner: Runner,
                root: str, baseline: Baseline, head: str) -> str:
    """Run the local review via the runner and return its text, validated to
    carry the `REVIEW_COMPLETE` trailer and stamped with the model and the
    commit it judged. Pure compute plus the stamp: reads, never writes.

    [LAW:single-enforcer] the trailer check lives here, once, for every runner —
    a runner owns only its own exit/timeout handling; the verdict contract that
    is identical across all local reviewers is enforced in exactly one place."""
    prompt = build_prompt(owner, repo, pr_num, root, baseline, head)
    review = runner.run(prompt, review_brief(), root).strip()
    if not _trailer(review):
        raise RuntimeError(
            f"{runner.cli} review produced no `REVIEW_COMPLETE: <N>` trailer — the "
            "verdict is missing, not clean; do not treat this as a clean review."
        )
    return _stamp(review, runner.model, head)


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
    """Ensure a current verdict exists for the PR's head commit.

    This is an idempotent upsert, not an unconditional run. A pass is warranted
    when the author has pushed code since this model's last verdict, or has said
    something new on the PR (a pushback deserves an answer — and without that
    second condition the caller's loop would spin forever: the author argues,
    the reviewer never re-runs, `fetch` returns the same open findings). When
    neither is true, this model's standing verdict already covers this commit
    and re-running would buy an identical answer at full price.

    [LAW:effects-at-boundaries] the expensive effect is performed here at the
    edge, and the edge is the right place to decide whether it is needed at all —
    the same shape as any idempotent write. Nothing downstream branches: callers
    get a verdict covering head either way.

    The marker makes a real run observable on the PR the moment it starts —
    before the review (minutes) finishes — mirroring the visible /opencode
    trigger comment. It carries no verdict stamp, so fetch() never mistakes it
    for the verdict."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    root = _repo_root(owner, repo, pr_num)
    head = _resolve(root, github_threads.head_sha(owner, repo, pr_num))
    baseline = _baseline(owner, repo, pr_num, root, head, runner.model)

    if baseline.sha == head and not _human_replies(owner, repo, pr_num, baseline.since):
        return {"triggered": False, "comment_url": None, "reason": "verdict current"}

    _post_comment(
        owner, repo, pr_num, f"{runner.marker}\n\n{MARKER_TOKEN}",
        pr_url, "trigger marker",
    )
    review = _run_review(owner, repo, pr_num, runner, root, baseline, head)
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


def _latest_review_comment(owner: str, repo: str, pr_num: int, model: str):
    """The current verdict from `model`: `(n, comment)` for the newest PR issue
    comment whose body carries a verdict stamp naming this model, or None if
    none exists.

    Keyed on the engine's verdict stamp — not on author, and not on the
    contract trailer. The stamp is the one thing only the engine writes, so it
    is the one thing that cannot be forged by prose; and it is model-scoped, so
    the verdict read back is the one the matching configuration produced. The
    count still comes from the `REVIEW_COMPLETE: <N>` trailer, the model's
    contract — its last match, per `_trailer`, never a prose quote of an
    earlier count. [LAW:no-silent-failure] a stamped comment with no trailer is
    a verdict whose count is missing — not zero, and not skippable — so it
    halts. trigger() posts a fresh verdict immediately before fetch() runs, so
    the newest such comment is always the current review.
    [LAW:one-source-of-truth]
    """
    comments = _gh_json(
        "api", f"repos/{owner}/{repo}/issues/{pr_num}/comments?per_page=100",
        "--jq", "[.[] | {author: .user.login, body, created_at}]",
    ) or []
    best = None  # (created_at, n, comment)
    for c in comments:
        m = VERDICT_RE.search(c.get("body") or "")
        if not m or m.group(1) != model:
            continue
        t = _trailer(c.get("body") or "")
        if not t:
            raise RuntimeError(
                f"Verdict comment by {c.get('author')} on {owner}/{repo}#{pr_num} "
                f"carries {model}'s verdict stamp but no `REVIEW_COMPLETE: <N>` "
                "trailer — the count is missing, not zero; do not treat this as "
                "a clean review."
            )
        if best is None or c["created_at"] > best[0]:
            best = (c["created_at"], int(t.group(1)), c)
    if best is None:
        return None
    return best[1], best[2]


def fetch(pr_url: str, runner: Runner) -> dict:
    """Return the current review's pending findings in canonical form — the
    verdict read back being the one `runner.model` produced: each provider
    module passes its own `RUNNER` through, so a provider never reads another
    model's verdict as its own.

    [LAW:verifiable-goals] `N == 0` is the one signal that establishes 'clean'
    and ends the skill's loop. While `N > 0`, the whole verdict comment is one
    unresolved finding carrying every concern; the author addresses them,
    re-triggers, and the next review's N is the convergence signal.

    [LAW:no-silent-failure] no stamped verdict from this model means the review
    never ran (or its comment was dropped) — halt; never read it as a clean
    pass."""
    owner, repo, pr_num = github_threads.parse_pr(pr_url)
    verdict = _latest_review_comment(owner, repo, pr_num, runner.model)
    if verdict is None:
        raise RuntimeError(
            f"No verdict comment from {runner.model} on {owner}/{repo}#{pr_num} — "
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
