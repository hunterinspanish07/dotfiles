---
name: address-pr-reviews
description: Address open PR review findings with judgment — read every finding, decide whether the feedback is right, fix or push back, resolve, and re-review by pushing. Repeat until clean. Use when the user says "address the PR review", "handle the review threads", "go through the review comments", or asks to respond to PR feedback on a specific PR or the current branch's PR.
---

# Address PR Review Findings

Read every pending review finding on the PR, address each one, push your fixes (which re-runs the reviewer), repeat until clean. Same model people use at a real company: handle reviewer findings AND human-reviewer threads in one pass, push back with reasoning when you disagree, resolve, re-review.

[LAW:one-source-of-truth] `provider.fetch` is the single source of pending findings for this loop — every open finding on the PR, keyed by `thread_id` (when available). There is no second stream.

**Provider** — the active review backend is loaded from `provider.json` in the skill directory (or `PR_REVIEW_PROVIDER` env var). The provider contract is in `PROVIDER_CONTRACT.md`. To switch providers, change `provider.json`; the loop below does not change.

```python
# Load the provider once at the start of the loop
import provider_loader
provider = provider_loader.get()  # reads provider.json, validates CAPABILITIES
# or pin one explicitly for this session: provider_loader.get("adversarial")
```

## Setup — derive PR_URL, OWNER, REPO, PR_NUM once

If the user didn't give you a PR number, infer it:

```bash
PR_URL=$(gh pr view --json url --jq .url)
read -r OWNER REPO PR_NUM < <(echo "$PR_URL" | sed -E 's#.*github\.com/([^/]+)/([^/]+)/pull/([0-9]+).*#\1 \2 \3#')
```

All subsequent commands use `$OWNER`, `$REPO`, `$PR_NUM`, and `$PR_URL`.

## Preflight — confirm the reviewer is installed

When `provider.CAPABILITIES["setup_check"]` is `True`, run the preflight and halt on failure:

```python
check = provider.setup_check(OWNER, REPO)
if not check["installed"]:
    raise SystemExit(f"Reviewer not installed: {check['message']}")
```

[LAW:no-silent-failure] a missing reviewer is the one failure that would otherwise look like "clean review, zero findings." Surface it as a hard stop, never an empty pass.

## The loop

Repeat until **step 2 returns zero unresolved findings**:

### 1. Trigger (if required) and wait for the review to finish

If `provider.CAPABILITIES["trigger"]` is `True`, request a review explicitly:

```python
provider.trigger(PR_URL)
```

Then wait for the review to complete (all providers, always):

```python
result = provider.wait(PR_URL)
```

Blocks until the review for the PR's **current head SHA** reaches `completed`, then returns `{status, conclusion, sha, url}`. If the head SHA's review is already complete (nothing new pushed), it returns at once.

[LAW:no-silent-failure] if `conclusion` is anything other than `success`, the reviewer itself errored — its findings are absent, not empty. Stop and surface the run `url`; do not treat a failed run as a clean review.

### 2. Fetch all pending review findings

```python
data = provider.fetch(PR_URL)
```

Returns canonical JSON: every open finding on the PR keyed by `thread_id` (nullable for providers without GitHub threads). One shape per finding.

Schema:

```json
{
  "findings": [
    {
      "file": "path/to/file.py",
      "line_start": 42,
      "line_end": 42,
      "body": "This silently swallows the error — surface it instead.",
      "author": "github-actions",
      "thread_id": "PRRT_xyz...",
      "is_resolved": false,
      "thread_comments": [
        {"author": "github-actions", "body": "This silently swallows the error — surface it instead."},
        {"author": "alice", "body": "agreed, fix incoming"}
      ]
    }
  ]
}
```

**Unresolved findings** = every entry where `is_resolved` is false. `thread_id` is non-null when the provider declares `resolve: True`. If the unresolved list is empty, **the loop is done** — step 1 already guaranteed the run completed, so empty is unambiguous. Proceed to **Finalize** below.

[LAW:verifiable-goals] this empty `fetch` is the **only** thing that establishes done. Never infer doneness from "I pushed my fixes" or "I addressed everything" — re-run `fetch` and read zero unresolved. A fixed-but-unresolved finding still counts as unresolved here, which is the safety net: it re-surfaces as `already_fixed`, and you resolve it now rather than leaving it open forever.

> **Read `thread_comments` before deciding.** A finding may already contain replies (yours from a prior iteration, a human's pushback on the reviewer, or a back-and-forth). The full chain is in `thread_comments`; `body` is just the first comment for quick scanning.

> **`line_start` may be `null`** for a file-level (non-line-anchored) comment. Open the file and read the `body`/`thread_comments` for context; the finding still resolves by `thread_id` like any other.

### 3. For each unresolved finding

Open the file at `file:line_start`. Read `body` and the full `thread_comments` chain. Classification is the same regardless of `author`:

- **valid** — reviewer is right; apply the fix
- **different_fix** — reviewer identified a real issue but proposed the wrong fix; apply a better one
- **invalid** — reviewer is wrong, or the suggestion violates an architectural law (defensive null guards, silent fallbacks, mode explosion, duplicate enforcement, control-flow in place of data-flow variance, etc.). Push back and **cite the law** (`[LAW:no-defensive-null-guards]`)
- **already_fixed** — resolved by a later commit; note and resolve

Handling a finding is **one atomic unit with a single postcondition: the finding is resolved or acknowledged**. Do the whole unit for the current finding and verify it before opening the next.

**Reply** (when the provider supports GitHub threads):

```bash
gh api graphql -f query='
mutation($id:ID!,$body:String!){
  addPullRequestReviewThreadReply(input:{pullRequestReviewThreadId:$id,body:$body}){ comment{id} } }
' -F id="$THREAD_ID" -F body="Proposal: ..."
```

**Resolve** — when `provider.CAPABILITIES["resolve"]` is `True`, resolve through the provider:

```python
provider.resolve(THREAD_ID)
```

[LAW:single-enforcer] resolve through the provider, never a raw mutation — it's the one verified path that confirms resolution was accepted, so a resolve that didn't take can't pass as done. [LAW:no-ambient-temporal-coupling] it's gated, not deferred: the provider call must succeed for the current finding **before** you open the next. "Resolve them all after I push" is the exact path that drops them; there is no batch-resolve-later step.

When `provider.CAPABILITIES["resolve"]` is `False`, findings have no resolvable thread — note each finding's disposition in a reply if the provider supports it, then move on. The loop converges when `fetch` returns zero open findings.

[LAW:dataflow-not-control-flow] resolve vs. acknowledge is a value the capability flag carries — the same loop body runs every time; the flag picks the action.

### 4. Address failing checks

Check the PR for any failing checks. Address them before continuing.

### 5. Commit and push your fixes

Commit messages describe the **why** (architectural concern), not "address review comment" — each commit must stand alone in `git log`. Batch related concerns; separate unrelated.

Pushing triggers re-review for providers that auto-fire on push (`trigger: False`). If an iteration made no code change — only pushbacks and resolves — the head SHA is unchanged, its run is already complete, and step 1 returns immediately; the loop converges via step 2's empty list. For providers that require explicit triggering (`trigger: True`), pushing does not automatically re-run the reviewer — the `trigger` call in step 1 handles that. The rare case of forcing a re-run without a new commit for workflow-based providers is `gh run rerun <run-id>`.

### 6. Go to step 1.

## Finalize — when the loop exits clean

The loop exits with zero unresolved findings after a clean re-review — the PR is green and reviewed. What happens next is **not** unconditional: it is one of two typed terminal arms, and the discriminator is the **autonomy grant**, never the agent's read of the room.

[LAW:types-are-the-program] `Finalize = StopForHumanMerge | MergeAndChain`. [LAW:dataflow-not-control-flow] the arm is selected by a fact on disk — does an active grant authorize *this* ticket — not by whether the user seems present, whether merging feels bold, or whether stopping feels safer. [LAW:single-enforcer] that fact comes from the one grant authority (`~/.claude/skills/lib/autonomy-grant.py`); this skill never reimplements the rule or mints a second authorization signal. Per `<ticket-lifecycle>` the agent still owns its close-out — but "close-out" means *driving the PR to the terminal state the grant authorizes*, which by default is "green, reviewed, ready for the human to merge."

### Select the arm

Identify the ticket this PR closes (`$TICKET_ID` — from the PR body, branch name, or the ticket worked this session), then ask the single grant authority whether autonomy is authorized for it:

```bash
TICKET_ID=...   # the ticket this PR closes
if ~/.claude/skills/lib/autonomy-grant.py authorized "$TICKET_ID"; then
  ARM=MergeAndChain          # Hunter granted bounded autonomy for this ticket
else
  ARM=StopForHumanMerge      # the default — no grant, ticket not in scope, or already done
fi
```

A nonzero exit — no grant file, ticket outside the grant's frozen scope, ticket already completed, or *any* error reading the grant — selects **StopForHumanMerge**. That is the safe direction: absent positive authorization, the human merges, never the agent.

**StopForHumanMerge is a legitimate terminal arm, not a "skip."** The earlier framing — that no "skip/ask/hold" arm exists and the agent always merges-and-chains — is replaced: the grant, a value on disk, now selects between two *prescribed* terminals. What remains forbidden is overriding the arm the grant selects for reasons of mood or presence — merging when no grant authorizes it, or stopping when one does, because the user seemed around or the `/clear` felt disruptive. "Presence is irrelevant" still holds: presence was never the discriminator and is not now — the grant is. Execute the arm it selects, as written.

### Arm — StopForHumanMerge (default)

The review loop already did the work: the PR is green and reviewed. Nothing remains but to hand it to Hunter. Report, in this turn:

```
PR #<num> — <one-line description> — green & reviewed, ready for your merge.
<anything Hunter should know before merging: a competing open PR that overlaps this one's files, a follow-up this surfaced>
```

Then **STOP**. Do NOT merge, do NOT `lit done` (the ticket is not merged — its open status correctly mirrors that), do NOT recap-as-merged, do NOT fire a bottle, do NOT remove the worktree (Hunter may want changes). To let the agent merge and chain instead, Hunter authorizes a pool with `/auto`.

### Arm — MergeAndChain (an active grant covers this ticket)

Hunter has granted bounded autonomy for this ticket. Run the close-out — merge, close, recap — then chain the next eligible ticket in the grant's pool.

[LAW:one-source-of-truth] **follow the tooling's runtime guidance.** Each step's tool (`gh pr merge`, `lit done`, `/recap`) emits its own instructions at runtime — preview tokens, next-step hints, branch-protection messages, admin-bypass prompts, apply-token strings, output paths. The skill describes the *shape* of each step; the tool itself is the authoritative source for *how* to follow through. Read what the tool prints and do what it says — don't paper over a warning, don't guess past a prompt, don't substitute the skill's wording when the tool gave you a literal token or path to use.

#### A. Refresh onto the live integration branch, then merge

Before merging, rebase onto what the integration branch *actually is right now* — another session or PR may have merged into it while this loop ran. [LAW:no-silent-failure] a stale base is the "staging moved mid-session" hazard; resolve it here, never merge blind over it. The base is detected, never assumed (`main` is often not the merge target — it may be `staging`/`dev`):

```bash
BASE=$(bash ~/.claude/skills/lib/integration-branch.sh) || { echo "stop: cannot resolve integration branch"; exit 1; }
git fetch origin
git rebase "origin/$BASE"
```

- **Clean rebase** → push the refreshed branch (`git push --force-with-lease`). CI re-runs against the true integration state; the loop's clean review still holds because the diff is unchanged.
- **Conflict** → you are in this ticket's own worktree with full context. Resolve it, re-run the ticket's verification (tests/build), then continue. If you cannot resolve it confidently, STOP and surface — never force a merge over a conflict you don't understand.
- **Competing open PR** → check for other open PRs targeting `$BASE` whose changed files overlap yours; if any do, note it in the recap as a heads-up ("PR #N also touches `<file>` — merging may conflict for them"). Flag, don't block: `gh pr merge` itself refuses a real conflict, so the base is never silently corrupted.

Then merge:

```bash
gh pr merge "$PR_URL" --squash --delete-branch
```

Squash is the repo's configured merge strategy. `--delete-branch` cleans up the remote branch (and the local one if checked out). [LAW:one-source-of-truth] `gh pr merge`'s exit code is the canonical signal of merge success — failure (required checks not satisfied, merge conflict, branch protection) halts Finalize. Don't add a `gh pr view --json merged` check as a second source; the exit code is the truth. At that point the agent's job changes from "close out" to "fix the merge blocker."

[LAW:no-silent-failure] in MergeAndChain a merge blocker — or a rebase conflict you cannot resolve confidently (see the **Conflict** bullet above) — halts the *chain*, not just this ticket. Retire the grant and report what shipped, what's left, and why it stopped:

```bash
~/.claude/skills/lib/autonomy-grant.py stop
```

The chain stops on the first failure or blocker by design; it never skips a stuck ticket to keep going.

Once the merge succeeds, retire this ticket's worktree. You are *inside* it, so step out to the main checkout first — a stale worktree pins a now-deleted branch and clutters the next session:

```bash
MAIN=$(cd "$(git rev-parse --git-common-dir)/.." && pwd)
cd "$MAIN"
git worktree remove "$MAIN/.claude/worktrees/$TICKET_ID" --force
```

(If this ticket was worked in an old-style in-place branch rather than a worktree, there is nothing to remove — skip it. Any leftover local branch cleanup follows `gh`'s own runtime guidance.)

#### B. Close the lit ticket

```bash
lit done "$TICKET_ID"
```

The ticket is the one this PR closed — pull it from the PR body, branch name, or the ticket you were working on in this session, and assign it to `$TICKET_ID`. The code block above is the canonical case: a confidently identified `$TICKET_ID`. Don't run `lit done` with an empty, guessed, or unverified value. `lit done` is a two-phase transition: the first call prints a preview with an apply token; capture it as `$TOKEN` and rerun with `--apply="$TOKEN"` to commit. For an out-of-band PR with no associated lit ticket, Step B is a no-op — skip the command entirely and note the missing-ticket case in the recap so the next agent sees it.

#### C. Recap the merged work

Invoke `/recap` with a short note describing what was merged. The recap is the durable historical record — what shipped, what's left, what to watch out for. It lives in the project's recap log; future sessions browsing history read it there.

#### D. Chain the next eligible ticket

The grant already froze a human-vetted pool, so there is no candidate re-classification to do here — [LAW:single-enforcer] eligibility and risk were judged once, at grant time in `/auto`. This step only advances the chain.

First record that this ticket merged, so the grant's pending set shrinks:

```bash
~/.claude/skills/lib/autonomy-grant.py complete "$TICKET_ID"
```

Then ask the grant authority what remains, and let the answer pick the terminal:

```bash
PENDING=$(~/.claude/skills/lib/autonomy-grant.py pending)
```

[LAW:dataflow-not-control-flow] the value of `PENDING` selects the terminal; neither branch is a judgment call.

- **Pool drained** (`PENDING` empty) → the grant is fulfilled. Retire it, then report — what shipped across the chain, that nothing eligible remains, and any **open** tickets created *after* the grant (never in scope, so NOT auto-run; name them so Hunter can decide). Do **not** fire a bottle; there is nothing authorized left to pick up. Stop here.

  ```bash
  ~/.claude/skills/lib/autonomy-grant.py stop
  ```

- **Pool has more** (`PENDING` non-empty) → hand the next ticket to a fresh context. The bottle `/clear`s the pane and pastes `/next`; with the grant still active, that `/next` scopes itself to the eligible set (see the `next` skill), so the chain never wanders outside the authorized pool.

  ```bash
  ~/.claude/skills/message-in-a-bottle/bin/message-in-a-bottle "$(cat <<'EOF'
Last session shipped PR #<num> — <one-line description of what merged>.
An autonomy grant is active and the eligible pool still has tickets. Forward
notes the next agent should know: <in-flight context, follow-ups this PR
surfaced, things to watch out for>.

/next
EOF
)"
```

  [LAW:one-source-of-truth] the bottle's content derives from the same authored recap as step C — past-tense canonical form vs forward-looking handoff, one substrate for two purposes. The bottle script needs tmux and fails loudly outside it; it takes **only** the message — its delay is fixed internally, so never pass a leading number (it has no delay parameter and would fold the number into the message body).

Then stop. This ticket is shipped and recorded; either the chain continues in a fresh context or the grant is retired and reported.

## Rules

- **You own the close-out — to the terminal the grant authorizes.** When the loop exits clean, run Finalize; the grant selects the terminal. With **no active grant** (the default), drive the PR to green-and-reviewed and STOP at "ready for your merge" — that is the authorized close-out, *not* a punt, because merge authority is human-gated by default. With **an active grant covering the ticket**, merge, close the lit ticket, recap, and chain the next eligible ticket via the bottle — and retire the grant when the pool drains or any ticket fails. What is still forbidden: leaving a PR half-reviewed, or overriding the grant's choice because the user seemed present. Eligibility and risk are judged once, at grant time in `/auto`; Finalize only executes the arm the grant selects.
- **Architectural laws override reviewer authority.** Refuse suggestions that violate `[LAW:...]`. Cite the law in the pushback reply on the thread — that text is the durable record of why the code is the way it is.
- **Resolve every finding you addressed, including pushbacks — through `provider.resolve(thread_id)`, and only advance once it confirms.** The reviewer doesn't reply; your comment is the record. Open findings accumulate forever. Resolution is the step that gets silently dropped, which is why it runs through the provider's verified path, not a raw mutation.
- **Conflicts between findings** — surface to the user before acting. Don't pick a side silently.
