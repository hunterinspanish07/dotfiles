---
name: auto
description: Opt-in autonomous ticket execution. Triage the ready backlog into autonomous-OK vs keep-human, present the pool with a one-line reason for every held ticket, and — on ONE human confirmation — grant the agent bounded authority to merge-and-chain the approved tickets until the eligible pool empties. Use when the user says "/auto", "go autonomous", "run the backlog unattended", "auto mode", or asks to authorize the agent to merge and chain tickets on its own. Subcommands: `/auto status` (report the active grant), `/auto stop` (retire it).
---

# /auto — opt-in autonomous ticket execution

By default the workflow is **human-gated**: every ticket runs to a green, reviewed PR and then STOPS for Hunter to merge (see `address-pr-reviews` Finalize). `/auto` is the one mechanism that lifts that gate — and only for a set of tickets Hunter explicitly approves in this session.

The authority is a **grant**: a durable file recording the FROZEN set of ticket IDs the agent may merge-and-chain without a human at the wheel. It is a file, not conversation, because every ticket runs in a freshly `/clear`-ed context — a new agent has amnesia and must re-read the authorization from disk.

[LAW:single-enforcer] the grant — its schema, its read/write, and the predicate "is autonomy authorized for ticket X" — lives in exactly one place: `~/.claude/skills/lib/autonomy-grant.py`. This skill, `next`, and `address-pr-reviews` all call it; none reimplements the rule. Never hand-edit a grant file or invent a second authorization signal.

```
~/.claude/skills/lib/autonomy-grant.py grant  --scope <ids> [--exclude <ids>]   # write the grant
~/.claude/skills/lib/autonomy-grant.py status [--json]                          # show it
~/.claude/skills/lib/autonomy-grant.py stop                                     # retire it
```

## Dispatch on the argument

[LAW:dataflow-not-control-flow] the argument selects one arm; the body of each arm is fixed.

- `/auto status` → run `~/.claude/skills/lib/autonomy-grant.py status` and relay it. Add live context: which pending tickets are still in `lit ready`, and any **open** tickets created *after* `granted_at` (not in scope — they will NOT be auto-run; name them so Hunter can `/auto stop` + re-`/auto` to include them). Done.
- `/auto stop` → run `~/.claude/skills/lib/autonomy-grant.py stop`, confirm the grant is retired. Done.
- `/auto` (no arg) or `/auto <epic|label>` → run the **triage → grant** flow below. The optional argument narrows the candidate set; absence triages the whole ready backlog.

## The triage → grant flow

Hunter must NOT have to name an epic or know the backlog. You do the reading and the judging; Hunter only approves the result.

### 1. Build the candidate set

```bash
lit ready                                   # the human-readable overview, for your context
lit queue --status open --limit 50 --json   # the machine-readable candidate list
```

For `/auto <epic|label>`, narrow first: `lit queue --status open --labels <label> --json`, or filter the queue to the named epic/topic. Tickets already labeled **`auto-hold`** are pre-excluded curation from a prior triage — keep them held and do NOT re-judge them; just carry their hold into the presentation.

### 2. Triage each candidate — default autonomous, the exception is argued

[LAW:dataflow-not-control-flow] every candidate gets the same read; the classification is a *value* (`autonomous-OK` | `keep-human` + reason), not a branch you skip. Read each ticket (`lit show <id> --json`) — enough to judge blast radius and whether a fresh agent could finish it unattended.

**Default = autonomous-OK** (tests, docs, internal refactors with tests, low-blast changes). Flag **keep-human** only when the ticket trips the rubric, and give a SPECIFIC one-line reason naming the actual hazard:

- touches **auth / session / security** — e.g. "rewrites session validation — a bug logs everyone out"
- runs a **DB migration** that is not cleanly reversible — e.g. "drops the `orders.legacy_total` column — irreversible once shipped"
- hits a **live external API** — e.g. "sends through the live Resend API — real emails to real users"
- **broad blast radius** in core/shared files — e.g. "edits the shared `apiClient` every service imports"
- **vague or missing acceptance criteria** — e.g. "DoD says 'make it faster' with no measurable target"

A generic "this seems risky" is unacceptable — if you can't name the hazard in one line, it is autonomous-OK.

### 3. Persist the keep-human decisions

For every newly-flagged keep-human ticket, persist the curation so future `/auto` runs inherit it:

```bash
lit label add <id> auto-hold
```

[LAW:single-enforcer] the `auto-hold` label is *eligibility* (durable curation), kept separate from the *grant* (active, bounded authorization). A label can hold a ticket out of autonomy, but it can never silently grant it — only an explicit grant written in step 5 does that. When a held ticket's blocker clears (criteria filled in, migration made reversible), lift it with `lit label rm <id> auto-hold`; it is then eligible on the next `/auto`.

### 4. Present the pool and STOP for ONE confirmation

This is the authority-granting moment — the single point where a human decides. Present, then **STOP**. Do NOT write the grant, do NOT start work, do NOT merge anything in this turn.

```
Autonomous pool (mode: run until empty, stop on any failure)

Will work unattended (N):
  • <id>  <title>
  • <id>  <title>

Held for you (M):
  • <id>  <title> — <specific one-line reason>
  • <id>  <title> — <specific one-line reason>

Reply "go" to grant autonomy for the N above, or tell me to drop/add tickets first.
```

Hunter may adjust ("drop X", "also hold Y", "include the held Z anyway") — apply the change, re-present, and STOP again. The grant is written only after an explicit go.

If the eligible set is **empty** (everything tripped the rubric, or the backlog is empty), there is nothing to authorize: present the held list (or "backlog is empty") and STOP **without** writing a grant.

### 5. On "go" — write the grant and kick off

```bash
~/.claude/skills/lib/autonomy-grant.py grant --scope <eligible ids> --exclude <held ids>
```

The scope is FROZEN here: tickets created later are not auto-run without a fresh review. Then start the **first** ticket by following the `next` skill — with the grant active it scopes itself to the eligible set. Each *subsequent* ticket is picked up in a fresh `/clear`-ed context by the bottle that `address-pr-reviews` Finalize fires; that onward `/next` stays inside the same eligible pool, and the chain stops + reports when the pool empties or any ticket fails. You do not manage the loop here — you grant, then hand to `next`.

## Rules

- **The pool is shown and confirmed before any merge.** A `/auto` that grants or merges without presenting the pool and getting an explicit go is the exact anti-pattern this feature exists to prevent.
- **Every held ticket carries a specific reason.** Name the hazard; never "might be risky."
- **One confirmation, not per-ticket.** The grant is the single authority-granting moment; after "go" the chain runs unattended until the pool drains or something fails.
- **Never reimplement the predicate.** Authorization is whatever `autonomy-grant.py authorized <id>` says — here, in `next`, and in `address-pr-reviews`. One enforcer, no second signal.
