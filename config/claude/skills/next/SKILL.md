---
name: next
description: Pull the next ticket
---

# Next

Pick up the next ready ticket and start work.

## Init

Run `lit quickstart` if you haven't already.  This provides instructions for using the work tracking system.

If the user provided specific information (e.g., a ticket id or area of the codebase to work on), SKIP THE REST OF THESE INSTRUCTIONS and follow the guidance from `lit quickstart` to follow the user instructions.  The following information is for determining which work to pick when the user did not specify.

## Finding work

Take a look at the backlog (`lit ready`) so you understand what work is in-progress or up next.  Now you need to decide whether you need to wrap up in-progress work or start new work.

### In progress work

If there are uncommitted changes or open PRs in the repo, we want to wrap these up before starting new work.

#### Uncommitted changes

determine if these changes are related to a backlog item.  If so, that is your current ticket.  If not, stop and think to your self: Are these changes worthwhile?  Accidential?  Incidental?  Should we commit or discard them?  Use your brain to think about the right solution because there is no one size fits all rule.

Examples:
- uncommitted pnpm lockfile update: check it out to discard, but then regengerate the lockfile as part of your commit when you do work
- Uncommitted typo in a random file: check it out to discard, it's not needed
- Minor update to the readme to include some more instructions: commit it and proceed
- Major update to the readme that is related to the work on the current branch: commit it and proceed
- Major update to work that is clearly NOT on this branch: stash it and proceed
- A half finished feature: find the ticket it's related to.  THIS TICKET IS YOUR ASSIGNED WORK. SKIP THE REST OF THE SKILL. If it's not related to a ticket you see, do a quick code review.  does the code look experimental and temporary or high quality?  Does it look complete or barely started?  Then briefly explain the state of the code, what it does, and any other info you have (no ticket, etc).  Ask if they want you to create a ticket and continue the work, if they want it to committed to work as part of a different ticket, or whether they want you to stash or discard it.  Follow that instruction.

Now there are no uncommitted changes.  If anything you did previously resulted in a reference to a specific ticket, THAT IS YOUR TICKET ID and you should skip the rest of this skill.

Do NOT proceed without either:
- no uncommitted changes
OR
- A ticket id to work on

#### Open PRs

Check for open PRs related to your current branch?  If there are, THIS IS YOUR TICKET!  Skip the rest of the skill and proceed to work that ticket.

We'll proceed with pulling from the backlog, but Open PRs are still relevant - you want to ensure you're building on old code or going to have significant merge conflicts.  But check this after you pull a ticket.

#### lit ready

Lit ready shows an overview of the epics and the top ticket in each epic, as well as any in-progress or orphaned tickets.

**If an autonomy grant is active, scope the pool first.** Before choosing anything, ask the single grant authority — read-only here; `/auto` and `address-pr-reviews` own the grant's lifecycle, `next` only reads it:

```bash
~/.claude/skills/lib/autonomy-grant.py status      # is autonomy authorized in this workspace?
~/.claude/skills/lib/autonomy-grant.py pending     # if so, the exact eligible ticket ids
```

When a grant is active, your candidate set is exactly its `pending` tickets intersected with what `lit ready` shows as actually workable — [LAW:single-enforcer] the grant is the one authority for what autonomy may touch, so a bottle's `/next` can never wander outside the authorized pool. Choose within that scoped set using the normal ordering below (orphaned first, then top of ready). If the scoped set is empty — every pending ticket is blocked, or the pool has drained — STOP and report what is pending-but-blocked; do NOT fall back to an unauthorized ticket. (A ticket id you were explicitly handed overrides this scoping — a human naming a ticket is a human decision, not autonomous picking.)

If there are any orphaned tickets, pull from those first.  Those tickets are abandoned and need someone to finish them.  

If there aren't any other tickets to pick up, take from the top of the ready queue.

3. **Read the ticket fully.** Title, description, acceptance criteria, comments, linked PRs, linked tickets. If the ticket references a spec, doc, or prior PR, read that too. You are about to author code that claims to satisfy this ticket — earn the right to claim it.

4. **Surface blockers before starting.**
   - Acceptance criteria missing or vague? Ask.
   - Depends on another ticket that isn't done? Stop and report.
   - Spec referenced but doesn't exist? Stop and report.
   - The ticket conflicts with current branch state or uncommitted work? Stop and report.
   - Don't paper over ambiguity with assumptions — confirm scope first.

IN ALL CASES YOU MUST DO AS MUCH OBVIOUS PREPATORY WORK AS YOU CAN BEFORE ASKING THE USER.

A mature engineer knows when to ask for help, and it isn't at the slightest hint of ambiguity and before they've put in a shred of effort to answer the question themselves.  "What do I do with this uncommited work" is only a good question if it isn't obviously work that Directly corresponds to the ticket matching the branch name.  "Acceptance criteria missing or vague?" It is only a good question if it's not clearly answerable via common sense or existing documentation or some other method. If there's real ambiguity, surface it. If it's just basic information about the repo, see if you can figure it out for yourself. In all cases, the user should be presented with The results of an Extremely quick Investigation rather than "Hey, I don't know what to do. Tell me what to do." 

5. **Set up an isolated worktree for the ticket.** Concurrent sessions must never share one working tree or HEAD — that is exactly how one agent's `checkout`/commit clobbers another's work. [LAW:no-shared-mutable-globals] every ticket gets its own worktree, branched off a fresh fetch of the integration branch, so any number of sessions run side by side without colliding.
   - **Find the integration branch** — the branch work merges *into*. Don't assume `main`/`master`; it is whatever recent PRs target (often `staging` or `dev`):
     ```sh
     BASE=$(bash ~/.claude/skills/lib/integration-branch.sh) || { echo "stop: cannot resolve integration branch"; exit 1; }
     ```
     The helper is the single source of truth. If it errors, STOP and surface it — never guess a base, branching off the wrong one is the staging-drift bug we're preventing. [LAW:no-silent-failure]
   - **Create the worktree off the fresh base and enter it** (resume into it if it already exists from earlier work on this ticket):
     ```sh
     ROOT=$(git rev-parse --show-toplevel)
     WT="$ROOT/.claude/worktrees/<ticket-id>"
     git fetch origin
     if [ -d "$WT" ]; then
       cd "$WT"                                                       # resume — worktree already exists
     elif git show-ref --verify --quiet "refs/heads/<ticket-id>"; then
       git worktree add "$WT" "<ticket-id>" && cd "$WT"              # branch exists (worktree was removed) → re-attach it
     else
       git worktree add "$WT" -b "<ticket-id>" "origin/$BASE" && cd "$WT"   # fresh; a real failure (bad base, etc.) surfaces here
     fi
     ```
     Keep the worktree dir out of git locally so it never shows as untracked and is never committed:
     ```sh
     printf '%s\n' '.claude/worktrees/' >> "$ROOT/.git/info/exclude"   # idempotent enough; one line, harmless if repeated
     ```
   - The worktree is clean by construction — you start from the real integration state, not a stale local HEAD. There is nothing to "figure out" about a dirty tree here; isolation gives you a fresh one every time.

6. **State the plan in one paragraph, then start.** What the ticket asks for, how you'll verify it's done (the machine-verifiable criterion), and the first concrete step. Then begin.

## General rules


## When to stop and ask

To be honest, rarely. You should be capable of figuring this stuff out. 

If you think that there's a chance that this could have negative impacts on other work, you can ask a quick question, but like I said, You need to make an attempt to answer the question yourself. 

That being said, here's a couple of scenarios which you can ask about: 
- The current branch already has uncommitted work that doesn't belong to a current ticket.
