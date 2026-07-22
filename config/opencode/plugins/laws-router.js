// laws-router.js — opencode port of the promptctl/laws skill-router.
//
// Claude Code ships the laws as a plugin: a SessionStart/UserPromptSubmit hook injects
// routing text every turn, and the model loads the ONE matching medium via Skill(laws:*).
// opencode has neither that hook nor a Skill tool — but it has two primitives that compose
// into the same behavior:
//   - experimental.chat.system.transform: append routing text to the system prompt every turn
//     (same durability as Claude Code's per-message re-injection).
//   - custom tools: expose each medium's law skill as a tool the model calls on demand.
// So the model is told, every turn, to load ONE medium; it calls laws_code / laws_prompt /
// laws_prose / laws_ticket; the tool returns that skill's body. Same shape as Claude Code.
//
// [LAW:one-source-of-truth] The skill bodies ARE the vendored promptctl/laws submodule — the
// exact files Claude Code reads. This plugin reads them at call time; it never copies them.

import { readFileSync, existsSync } from "node:fs"
import { homedir } from "node:os"
import { join, dirname } from "node:path"
import { fileURLToPath } from "node:url"

// Resolve the vendored laws directory. First existing candidate wins; if none resolve we
// throw at load, so a moved/uninitialised submodule surfaces loudly instead of the router
// silently serving nothing. [LAW:no-silent-failure]
function resolveLawsDir() {
  const relToPlugin = () => {
    try {
      // …/config/opencode/plugins/laws-router.js → …/config/claude/vendor/laws
      return join(dirname(fileURLToPath(import.meta.url)), "..", "..", "claude", "vendor", "laws")
    } catch {
      return undefined
    }
  }
  const candidates = [
    process.env.LAWS_DIR,
    relToPlugin(),
    join(homedir(), "code", "dotfiles", "config", "claude", "vendor", "laws"),
  ].filter(Boolean)
  const found = candidates.find((dir) => existsSync(join(dir, "skills", "code", "SKILL.md")))
  if (!found) {
    throw new Error(
      `[laws-router] cannot locate the vendored promptctl/laws skills. Tried: ${candidates.join(
        ", ",
      )}. Set LAWS_DIR or run \`git submodule update --init\` in your dotfiles.`,
    )
  }
  return found
}

const LAWS_DIR = resolveLawsDir()
const SKILL_PATH = {
  code: join(LAWS_DIR, "skills", "code", "SKILL.md"),
  prompt: join(LAWS_DIR, "skills", "prompt", "SKILL.md"),
  prose: join(LAWS_DIR, "skills", "prose", "SKILL.md"),
  ticket: join(LAWS_DIR, "skills", "ticket", "SKILL.md"),
}

// Read once, reuse. The skills are static for the life of the process. [LAW:carrying-cost]
const cache = {}
function loadSkill(name) {
  if (cache[name] === undefined) cache[name] = readFileSync(SKILL_PATH[name], "utf8")
  return cache[name]
}

// Routing text — the medium table, pointing at THIS runtime's tool names (not Skill(laws:*)).
// Re-asserted on every turn via system.transform, so a long or compacted session still carries it.
const ROUTE_TEXT =
  "Before substantive work, identify the medium of your primary deliverable and load the ONE laws skill that matches by calling its tool: code - source, tests, schemas, configs, scripts, infrastructure - call laws_code; text another LLM will consume - task prompts, subagent instructions, guidance documents, skill bodies, hook text - call laws_prompt; tickets an agent will pull from a backlog and build one at a time - epics, issues, backlog planning, acceptance criteria - call laws_ticket; prose for humans - docs, READMEs, reports, messages - call laws_prose. Load one, not two: each carries a different standard, and stacking them lets one medium's rules corrupt another's work. Switch skills only if the medium itself changes."

// Engagement text — verbatim from the upstream skill-router: re-enter the philosophy each turn.
const ENGAGE_TEXT =
  "For the following request, please consider the laws and devices of your craft and directly consider how you will apply them to achieve the highest quality expression of your work. You can improve your results substantially by expressing this directly in the chat. Engaging with the laws and devices is a must. Although it may seem tedious to repeatedly derive these concrete details from the abstract concepts, that engagement is absolutely critical for achieving your highest quality expression. This is not a checklist to satisfy; this is a philosophy for maximizing successful achievement of your goals."

// A tool per medium. No args (empty ZodRawShape), no SDK import — a plain ToolDefinition, so the
// file stays self-contained and safe to symlink from dotfiles (no node_modules resolution needed).
function skillTool(name, description) {
  return {
    description,
    args: {},
    async execute() {
      return loadSkill(name)
    },
  }
}

export const LawsRouter = async () => ({
  "experimental.chat.system.transform": async (_input, output) => {
    output.system.push(`${ROUTE_TEXT}\n\n${ENGAGE_TEXT}`)
  },
  tool: {
    laws_code: skillTool(
      "code",
      "Load THE UNIVERSAL ARCHITECTURAL LAWS and domain bindings. Call BEFORE any code work - writing, editing, reviewing, refactoring, debugging, or designing code, tests, schemas, configuration, scripts, infrastructure, or system architecture. Do not apply to prose or LLM-prompt authoring.",
    ),
    laws_prompt: skillTool(
      "prompt",
      "Load the craft of writing for LLMs. Call BEFORE authoring any text another model will consume - task prompts, subagent instructions, guidance documents, skill bodies, hook text, CLAUDE.md/AGENTS.md.",
    ),
    laws_prose: skillTool(
      "prose",
      "Load the craft of writing prose for humans. Call BEFORE writing docs, READMEs, reports, or messages for people.",
    ),
    laws_ticket: skillTool(
      "ticket",
      "Load the craft of writing tickets for an agent to build. Call BEFORE breaking work into epics/issues, backlog planning, or writing acceptance criteria.",
    ),
  },
})
