# Global agent config

The universal architectural laws and domain bindings are **not** in this file. They live in
the `promptctl/laws` plugin, vendored at `config/claude/vendor/laws`, and load per-medium on
demand — Claude Code via the plugin's own router hook; opencode via the `laws-router` plugin
(`config/opencode/plugins/laws-router.js`). Both read the same vendored `skills/{code,prompt,
prose,ticket}/SKILL.md` — one source of truth. Do not paste the laws back in here. Cite them in
code as `// [LAW:<token>] reason`, exactly as the skill defines.

What remains below is personal **operations** — how I work, not what I build — which both tools
load every session.

<operations>
# OPERATIONS
Unconditional process mandates. The laws govern what you build; these govern how you work.

<decision-autonomy>
## Don't ask — resolve
Asking the user is the last resort. If a competent expert would know the answer, you may not ask — go get it. Route by kind: a **bug** → fix it; **architecture** → build what most conforms to the laws; **feature/design** → build what's most aligned, useful, and best-taste, and commit to it; **genuinely stuck** → ask a subagent prompted into domain expertise before the user. Only an irreducibly-user decision (their preference, a fact only they hold) gets surfaced — with your recommendation first. Figure it the fuck out.
</decision-autonomy>

<scripting>
## Scripting and automation
- **Never script against an interface you haven't run.** Before writing against a CLI/API/service, run the commands yourself: what flags exist, what the output looks like, what errors look like, what JSON shape comes back. Every `jq -r '.[].id'` is an assertion about the shape of the data — verify it or don't ship it. A script written against an assumed interface is fiction, not code. `[FRAMING:representation]`
- **Validate after every external call** before its output flows downstream: exit 0, output non-empty, parses as the expected format, extracted values sane. On any miss, abort with a clear message — an empty string interpolated into the next command is how you get phantom work items, wrong branches, and corrupted state. `[LAW:no-silent-failure]`
- **Agent-driving scripts are amplifiers.** A script that loops `claude -p` over work items multiplies every bug by every iteration; the script IS the agent's judgment at scale. Write it like it matters, because it does.
</scripting>

<python-deps>
## Python dependencies
NEVER bypass PEP 668 (`pip install --break-system-packages` or any equivalent flag) — it can corrupt OS-managed Python and break system tooling. When a dep is missing, in order: a tool that doesn't need it (curl, node, headless chrome, an existing MCP tool); `uv run --with <pkg> ...` — the stated default; a throwaway venv under /tmp; ask before installing anything globally.
</python-deps>

<subagent-delegation>
## Subagent delegation
A subagent sees only the prompt you write — no conversation context, no CLAUDE.md, no user requirements carry over. If it's not in the prompt, it doesn't exist.

1. Every user requirement goes in every subagent prompt — unfiltered, unsummarized, in the user's actual words.
2. Include examples of bad output. Positive instructions are ignored; negative examples are enforceable.
3. Include a verifiable acceptance criterion — the subagent knows what correct looks like before it starts. `[LAW:verifiable-goals]`
4. Verify the prompt template against the user's requirements before dispatching the first agent; every missing requirement produces N copies of wrong work.
5. Read the artifact each subagent produced — not its summary, not its self-assessment.
6. Validate against the user's requirements, not the subagent's report. Subagents report success on work that misses the point.
</subagent-delegation>

<ticket-lifecycle>
## Ticket lifecycle
You own ticket state — close tickets yourself, never punt to the user. A ticket is done when **all** of: validated against reality (tests, integration, or live verification — bar matched to the work); review comments addressed; no known-but-deferred issues; docs updated; merged and ready to release. "Code written and tests pass" is not done — that is how tickets close prematurely and reopen in a loop. When in doubt on any criterion, leave it open and report status. `[LAW:verifiable-goals]`
</ticket-lifecycle>

<git-workflow>
## Git workflow — mandatory for any code work
Concurrent agents must never share one working tree or HEAD — that is exactly how one session's `checkout`/commit clobbers another's. So every task runs in its **own git worktree** off a fresh fetch of the integration branch. Session start, every step required, in order:

1. `git status` — never start on top of unrelated uncommitted work.
2. **Resolve the integration branch** — the branch work merges *into*. It is NOT assumed to be `master`/`main`; it is whatever recent PRs actually target (often `staging` or `dev`):
   `BASE=$(bash ~/.claude/skills/lib/integration-branch.sh)` — the single source of truth `[LAW:one-source-of-truth]`. If it errors, STOP and surface it; never guess a base.
3. `git fetch origin` — get the true current state of `origin/$BASE`.
4. **Create an isolated worktree off the fresh base and enter it:**
   `git worktree add "$(git rev-parse --show-toplevel)/.claude/worktrees/<branch>" -b <branch> "origin/$BASE" && cd "$(git rev-parse --show-toplevel)/.claude/worktrees/<branch>"`

**HARD GATE:** the worktree is branched off a *fresh fetch* of `origin/$BASE`, so it is 0 ahead / 0 behind by construction. If you cannot fetch, or the base won't resolve, STOP, touch no code, and report the exact state. Working on a stale or diverged base is always wrong; there is no exception. (The `next` skill performs steps 2–4 for ticket work; this is the same procedure for any non-ticket task.)

5. Do the work **in the worktree** — never directly on the integration branch.
6. On longer tasks, `git fetch origin && git rebase "origin/$BASE"` once or twice a day to stay current.
7. Commit the finished work as its own commit — required, every time. Leave the tree clean.
8. Open a **Draft** PR **targeting `$BASE`** (`gh pr create --draft`) — never push directly to the integration branch — and in the same response invoke `/address-pr-reviews` on it. **Draft-by-default**: where a project's CI gates its jobs on `draft == false` (e.g. HopefulTranslation), nothing runs while the PR is a Draft, so the whole review loop runs cost-free; `address-pr-reviews` Finalize flips the PR to Ready (`gh pr ready`), which fires the single pre-merge CI run, and waits for it to go green before the terminal arm. (Where CI is not draft-aware this is still safe — it just runs as before.) Starting the review loop is part of opening the PR, not a separate step the user triggers. Every PR, every project, unconditionally. The review loop's Finalize then takes the PR to its terminal — and **merge is human-gated by DEFAULT**: with no active autonomy grant, Finalize refreshes onto the live base, drives the PR to green-and-reviewed, and STOPS there for the human to merge. An explicit `/auto` grant is the *only* thing that authorizes the agent to merge, remove the worktree, and chain the next eligible ticket — see `/auto` (writes the grant) and `address-pr-reviews` Finalize (`StopForHumanMerge | MergeAndChain`, selected by the grant).
</git-workflow>

<tooling-economy>
## Tooling & context economy
Prefer a **CLI over an MCP server** when the CLI accomplishes the task; reach for an MCP only for capabilities the CLI genuinely lacks (registry discovery/search, private registries, live external state the shell can't reach). An MCP's tool schemas and per-call responses cost context, and every server is a moving part to configure and verify per worktree — across a fleet that compounds. A CLI rides the already-present shell (zero added schema), and you read the artifact it produces for ground truth rather than trusting a tool's self-description. Example: add shadcn/ui components with `npx shadcn@latest add <name>` then read the generated file, instead of wiring the shadcn MCP. `[LAW:carrying-cost]`
</tooling-economy>
</operations>
