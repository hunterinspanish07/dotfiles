# dotfiles

Personal dotfiles, synced across machines. Right now this manages **Claude Code**
configuration — global skills, slash commands, and `CLAUDE.md` — and is built to
grow into the rest of my environment over time.

## Install

```bash
./install
```

Requires [`uv`](https://docs.astral.sh/uv/) (`brew install uv`). The `install`
script runs [dotbot](https://github.com/anishathalye/dotbot) via `uvx` (no
submodule, nothing installed globally) and symlinks the config into place per
`install.conf.yaml`. It's idempotent — re-run it any time, on any machine.

## Layout

```
config/claude/
  CLAUDE.md          → ~/.claude/CLAUDE.md     global instructions (Universal Laws + personal rules)
  commands/          → ~/.claude/commands/     slash commands (e.g. /recap)
  skills/            → ~/.claude/skills/        agent skills (see below)
install.conf.yaml    dotbot link map
install              dotbot wrapper (uvx dotbot)
```

Only these specific paths are linked into `~/.claude`; Claude Code's runtime
state (`sessions/`, `projects/`, `plugins/`, `settings.local.json`) is left
untouched.

## Skills

The `lit` agent-native workflow ([links-issue-tracker](https://github.com/promptctl/links-issue-tracker)):

- **`next`** — pull the next ready ticket and start work (`lit ready` → `lit start`).
- **`plan-feature`** — interview an idea, decompose into small `lit` tickets with
  machine-verifiable Definitions of Done, and stop for human approval (Gate 1)
  before filing.
- **`address-pr-reviews`** — read every open PR finding, fix or push back, resolve,
  re-review until clean, then finalize (merge, `lit done`, recap, handoff). Uses a
  pluggable review **provider** (see below).

Supporting / general skills (from [brandon-fryslie/dotfiles](https://github.com/brandon-fryslie/dotfiles),
[mattpocock/skills](https://github.com/mattpocock/skills)):

- **`grill-me`** — stress-test a plan by asking one tough design question at a time.
- **`groom-backlog`**, **`spec-create`** — backlog grooming and spec authoring.
- **`sheriff-is-in-town`**, **`message-in-a-bottle`** — workflow / session-handoff helpers.

### address-pr-reviews providers

The active review backend is chosen in
`config/claude/skills/address-pr-reviews/provider.json` (or the
`PR_REVIEW_PROVIDER` env var). See `PROVIDER_CONTRACT.md`.

- **`opencode`** (default) — drives the repo's `opencode` GitHub Actions reviewer:
  posts `/opencode`, waits for the run, reads findings as review threads.
- **`adversarial`** — runs a local headless `claude -p` reviewer instead (needs
  `claude` + `gh`).
- **`local`** — stub for a local agent (not implemented).

## Credits

Skill content adapted from [brandon-fryslie/dotfiles](https://github.com/brandon-fryslie/dotfiles)
and [mattpocock/skills](https://github.com/mattpocock/skills). The Universal Laws
in `CLAUDE.md` originate from brandon-fryslie/dotfiles.
