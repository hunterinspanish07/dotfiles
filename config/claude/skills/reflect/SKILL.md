---
name: reflect
description: Mine your own Claude Code transcripts for workflow friction and turn recurring friction into durable tooling — new skills, memories, permission allowlists, doc fixes — safely and reversibly. The self-improvement loop. Use when the user says "reflect", "run reflection", "mine my transcripts", "what's slowing me down", "improve my workflow from history", or when invoked headlessly by the scheduled daily run.
---

# reflect — the workflow self-improvement loop

You are closing a learning loop: your own JSONL transcripts record where work was
token-heavy, repetitive, ambiguous, or correction-prone. Your job is to find that
friction and **collapse it into durable artifacts** so the next cycle is cheaper —
the task that took four steps takes one. This runs both manually and as an unsupervised
daily job, so it must be **safe by construction**, not safe by review.

## Non-negotiable invariants (these are what make "drives better outcomes" enforceable)

- **Reversible.** Every change you apply is a *local* git commit in `~/code/dotfiles` on a
  `reflect/<date>` branch, message prefixed `reflect:`. **Never `git push`.** The user's undo
  is `git revert`. `[LAW:no-silent-failure]`
- **Blast-radius tiers.** You may auto-apply only **additive, reversible, GLOBAL** artifacts.
  You may **never** auto-apply, only propose in the digest:
  - hooks (they fire on every session, silently) ,
  - edits to existing load-bearing files (existing skills, `CLAUDE.md` laws, existing hooks),
  - any write into a project repo other than dotfiles (wrong branch / dirty tree risk).
- **Bounded.** ≤ 3 new artifacts per run. Dedup against what already exists first. GC the unused.
  `[LAW:no-mode-explosion]` `[LAW:carrying-cost]`
- **Self-measuring.** Every run first grades the previous run's artifacts against fresh friction.
  A loop that can't tell if it helped is churn. `[LAW:verifiable-goals]`
- **Mode-gated.** Read `mode` from `~/.claude/reflect/state.json`. `propose` → apply nothing, write
  the digest only. `apply` → auto-apply the safe tier. Default is `propose` until the user opts in.

## Procedure

### 1. Get the friction
Read the latest `~/.claude/reflect/friction-<date>.json`. The scheduled daemon runs the miner for
you (in its wrapper) before invoking this skill, so it usually already exists. If you are running
manually and today's file is missing, run the miner yourself:
```bash
python3 ~/.claude/skills/reflect/mine_friction.py ${REFLECT_SESSION_ID:+--exclude-session "$REFLECT_SESSION_ID"}
```
The miner only measures; all interpretation is yours. Under the daemon you run with a least-privilege
settings file: writes are path-scoped to what reflect owns, the only Bash allowed is local `git` on
`~/code/dotfiles` (for apply-mode commits) — no push, no arbitrary commands. If a step gets denied,
that is the sandbox working; note it in the digest rather than working around it.

### 2. Self-measure (close the prior loop)
Read `~/.claude/reflect/ledger.json` (prior cycles' applied artifacts, each tagged with the
friction signal it targeted). For each, check the fresh report: did that signal **drop**, stay
flat, or worsen? Record a verdict. An artifact that didn't help — or a skill it created that was
never invoked — becomes a **revert-proposal** in the digest. This is how the loop avoids drifting.

### 3. Cluster & decide the artifact
For each material friction cluster, ask the one question: *"What single artifact would have
collapsed this into one step?"* Map it:
- **Repeated multi-step command sequence** → a new **skill** (or a small helper script a skill wraps).
- **Permission friction / repeated prompts** → **permission allowlist** entries. Reuse the existing
  `/fewer-permission-prompts` logic rather than reinventing it.
- **Recurring user correction** (same redirection more than once) → a **feedback memory** capturing
  the lesson + *why*, and if it's a standing rule, a one-line `CLAUDE.md` clarification.
- **Repeated "where does X live / how do I Y" lookups** → a **reference memory** or doc note.
- **Long tool-chains for a recurring task type** → a skill that encodes the known-good sequence.
- **Loaded-but-never-used MCP servers / unused skills** → GC (step 6).

Ignore one-offs. Only recurring friction (seen across multiple sessions, or high count) earns an
artifact. `[LAW:dataflow-not-control-flow]` — you are turning repeated *runtime* branching into a
fixed reusable part.

### 4. Dedup & cap
Before creating anything: confirm no existing skill/memory/permission already covers it (list
`~/.claude/skills/`, read `MEMORY.md`, grep the settings allowlists). Drop duplicates. Keep the
top ≤ 3 highest-leverage new artifacts; defer the rest to the digest backlog.

### 5. Apply the safe tier — only if `mode == apply`
Route each artifact to its single owner `[LAW:one-source-of-truth]`:
- New global skill → `~/code/dotfiles/config/claude/skills/<name>/SKILL.md` (live next session via the symlink).
- Feedback/reference memory → the project memory dir + a one-line `MEMORY.md` pointer.
- Permission allowlist → the appropriate `settings.json` `permissions.allow`.
- Doc clarification → a small, additive edit to a global doc (never a law rewrite).
Then commit in dotfiles — but **guard the user's in-flight work first**. If the tree has
uncommitted changes that aren't reflect's own, do NOT switch branches (it would carry or conflict):
leave the new artifacts as untracked files and record "left uncommitted — dotfiles tree was dirty"
in the digest. Only when the tree is otherwise clean:
```bash
test -z "$(git -C ~/code/dotfiles status --porcelain | grep -v 'config/claude/skills/\|config/claude/settings.json\|config/claude/CLAUDE.md')" || { echo "dotfiles dirty — skipping commit"; }
git -C ~/code/dotfiles checkout -b reflect/$(date +%F) 2>/dev/null || git -C ~/code/dotfiles checkout reflect/$(date +%F)
git -C ~/code/dotfiles add config/claude/skills config/claude/settings.json config/claude/CLAUDE.md
git -C ~/code/dotfiles commit -m "reflect: <what + which friction it targets>"
```
Stay off the user's in-flight feature branch — use the dedicated `reflect/<date>` branch. **Never push.**

### 6. GC
Skills the loop itself created (tracked in the ledger) with **zero invocations over 2+ cycles** →
auto-retire (delete + commit). Human-created unused skills (e.g. `groom-backlog`, `spec-create` if
idle) → **propose** retirement in the digest only; never delete the user's own work. **Never GC or
even propose-retire `reflect` itself or the scheduler** — the engine shows 0 invocations by nature
and must be exempt, or the loop deletes itself.

### 7. Propose-only tier
Everything in the forbidden-to-auto list (hooks, edits to existing load-bearing files, project-repo
changes) → write as concrete, copy-pasteable proposals in the digest. Do not apply them.

### 8. Digest + ledger
Append a dated entry to `~/.claude/reflect/digest.md`:
- friction summary (top signals + counts), self-measure verdicts on the prior cycle,
- what was applied (with the dotfiles commit sha), what was GC'd, what is proposed-only.
Update `~/.claude/reflect/ledger.json` with this cycle's applied artifacts + their target signals so
the next run can grade them.

## Output
End with a tight report: the cycle's verdicts, what changed (reversible — name the branch/sha),
what's proposed for the user to apply, and the current `mode`. If `mode == propose`, state plainly:
*"propose-only — set `mode: apply` in `~/.claude/reflect/state.json` (or tell me once) to let me
apply the safe tier automatically."*
