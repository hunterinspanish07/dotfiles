#!/usr/bin/env python3
"""Deterministic friction miner for the `reflect` self-improvement loop.

Reads Claude Code JSONL transcripts and emits a structured friction report. This is
the pure-compute half of `reflect`: it does not interpret anything or decide what to
build — it only measures. The `/reflect` skill is the judgment layer that reads this
output. [LAW:effects-at-boundaries] — the only effects are reading transcripts and
(when not --dry) writing one JSON file + advancing the watermark.

The watermark makes runs incremental: each run only mines transcript *lines* newer
than the last run, so the loop never re-counts old friction. Reflect's own headless
sessions are excluded by both an explicit --exclude-session id and by auto-detecting
any session that invoked `/reflect` — otherwise the loop would mine itself and drift.
"""
from __future__ import annotations

import argparse
import dataclasses
import glob
import json
import os
import re
from collections import Counter
from datetime import datetime, timedelta, timezone

HOME = os.path.expanduser("~")
DEFAULT_PROJECTS = os.path.join(HOME, ".claude", "projects")
DEFAULT_STATE = os.path.join(HOME, ".claude", "reflect", "state.json")
DEFAULT_OUTDIR = os.path.join(HOME, ".claude", "reflect")
SKILL_DIRS = [
    os.path.join(HOME, ".claude", "skills"),  # user-global (dotfiles symlink)
]

_CORRECTION = re.compile(
    r"\b(no|nope|don'?t|do not|actually|wrong|stop|instead|not that|undo|revert|"
    r"that'?s not|why did|you (missed|forgot|broke|didn'?t)|please don)\b",
    re.I,
)
_BROKEN_SHELL = re.compile(r";\s*(&&|\|\|)")  # e.g. `cd x; && echo` — a real construction bug


def parse_ts(s: str | None) -> datetime | None:
    if not s:
        return None
    try:
        return datetime.fromisoformat(s.replace("Z", "+00:00"))
    except ValueError:
        return None


_SETUP_HEADS = {"cd", "source", ".", "export", "pushd", "popd", "set"}
_SUBCMD_HEADS = {"git", "gh", "lit", "npm", "npx", "python", "python3", "uv", "cargo", "pytest"}


def norm_bash(cmd: str) -> str:
    """Collapse a Bash command to a stable 'shape' so repeats cluster together.

    Leading `cd`/`source`/`export` chaining is skipped so the *real* repeated work
    surfaces — otherwise nearly everything shapes to 'cd' and the signal is lost.
    """
    for seg in re.split(r"&&|\|\||;|\|", cmd.strip()):
        toks = seg.split()
        if not toks or toks[0] in _SETUP_HEADS:
            continue
        head = toks[0]
        if head in _SUBCMD_HEADS and len(toks) > 1:
            return f"{head} {toks[1]}"
        return head
    first = cmd.strip().split()
    return first[0] if first else "(empty)"


@dataclasses.dataclass
class Friction:
    api_retries: int = 0
    api_errors: int = 0
    hook_errors: int = 0
    permission_friction: int = 0
    tool_mix: Counter = dataclasses.field(default_factory=Counter)
    bash_shapes: Counter = dataclasses.field(default_factory=Counter)
    bash_examples: dict = dataclasses.field(default_factory=dict)
    broken_shell: Counter = dataclasses.field(default_factory=Counter)
    skill_usage: Counter = dataclasses.field(default_factory=Counter)
    mcp_usage: Counter = dataclasses.field(default_factory=Counter)
    corrections: list = dataclasses.field(default_factory=list)
    chains: list = dataclasses.field(default_factory=list)  # (tool_count, [tools], session)
    assistant_turns: int = 0
    sessions: set = dataclasses.field(default_factory=set)
    transcripts: int = 0
    excluded_sessions: set = dataclasses.field(default_factory=set)


def session_invoked_reflect(path: str) -> bool:
    """A session that ran /reflect must be excluded so the loop never mines itself."""
    try:
        with open(path) as fh:
            for line in fh:
                if '"/reflect"' in line or "<command-name>/reflect" in line or "skills/reflect" in line:
                    return True
    except OSError:
        return False
    return False


def mine(projects_dir: str, since: datetime, exclude_session: str | None) -> Friction:
    fr = Friction()
    files = glob.glob(os.path.join(projects_dir, "*", "*.jsonl"))
    for path in files:
        sid_guess = os.path.splitext(os.path.basename(path))[0]
        if exclude_session and sid_guess == exclude_session:
            fr.excluded_sessions.add(sid_guess)
            continue
        if session_invoked_reflect(path):
            fr.excluded_sessions.add(sid_guess)
            continue
        fr.transcripts += 1
        chain = 0
        chain_tools: list[str] = []
        cur_session = sid_guess
        with open(path) as fh:
            for raw in fh:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    o = json.loads(raw)
                except json.JSONDecodeError:
                    continue
                ts = parse_ts(o.get("timestamp"))
                if ts and ts < since:
                    continue  # incremental: skip lines older than the watermark
                sid = o.get("sessionId")
                if sid:
                    cur_session = sid
                    fr.sessions.add(sid)

                if o.get("isApiErrorMessage"):
                    fr.api_errors += 1
                if o.get("retryAttempt") is not None:
                    fr.api_retries += 1
                if o.get("hookErrors"):
                    fr.hook_errors += 1
                if (sk := o.get("attributionSkill")):
                    fr.skill_usage[sk] += 1
                if (ms := o.get("attributionMcpServer")):
                    fr.mcp_usage[f"{ms}/{o.get('attributionMcpTool')}"] += 1

                if o.get("type") == "assistant":
                    fr.assistant_turns += 1

                msg = o.get("message")
                if not isinstance(msg, dict):
                    continue
                role = msg.get("role")
                content = msg.get("content")

                # Real typed user prompt → close the previous tool-call chain. Harness
                # and tool wrappers all start with '<' (<command-name>, <bash-stdout>,
                # <local-command…, <system-reminder>), so that one guard excludes them.
                if (
                    role == "user"
                    and not o.get("isMeta")
                    and isinstance(content, str)
                    and content.strip()
                    and not content.strip().startswith("<")
                ):
                    if chain >= 6:
                        fr.chains.append((chain, chain_tools[:12], cur_session))
                    chain, chain_tools = 0, []
                    cs = content.strip().replace("\n", " ")
                    if len(cs) < 240 and _CORRECTION.search(cs):
                        fr.corrections.append({"text": cs[:160], "session": cur_session,
                                               "ts": o.get("timestamp")})

                if isinstance(content, list):
                    for b in content:
                        if not isinstance(b, dict):
                            continue
                        bt = b.get("type")
                        if bt == "tool_use":
                            name = b.get("name")
                            fr.tool_mix[name] += 1
                            chain += 1
                            chain_tools.append(name)
                            if name == "Bash":
                                cmd = (b.get("input") or {}).get("command", "") or ""
                                shape = norm_bash(cmd)
                                fr.bash_shapes[shape] += 1
                                fr.bash_examples.setdefault(shape, cmd.strip()[:120])
                                if _BROKEN_SHELL.search(cmd):
                                    fr.broken_shell[shape] += 1
                        elif bt == "tool_result":
                            rc = b.get("content")
                            txt = rc if isinstance(rc, str) else json.dumps(rc)
                            if re.search(r"permission|denied|not allowed|requested permission", txt, re.I):
                                fr.permission_friction += 1
        if chain >= 6:
            fr.chains.append((chain, chain_tools[:12], cur_session))
    return fr


def installed_skills() -> set[str]:
    names: set[str] = set()
    for root in SKILL_DIRS:
        for p in glob.glob(os.path.join(root, "*", "SKILL.md")):
            names.add(os.path.basename(os.path.dirname(p)))
    return names


def report(fr: Friction, since: datetime, watermark_new: str) -> dict:
    installed = installed_skills()
    used = set(fr.skill_usage)
    unused = sorted(installed - used)
    bash_rows = [
        {"shape": s, "count": c, "example": fr.bash_examples.get(s, ""),
         "broken": fr.broken_shell.get(s, 0)}
        for s, c in fr.bash_shapes.most_common(30)
    ]
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "window": {"since": since.isoformat(), "watermark_new": watermark_new},
        "scope": {
            "transcripts": fr.transcripts,
            "sessions": len(fr.sessions),
            "assistant_turns": fr.assistant_turns,
            "excluded_reflect_sessions": sorted(fr.excluded_sessions),
        },
        "instability": {
            "api_retries": fr.api_retries, "api_errors": fr.api_errors,
            "hook_errors": fr.hook_errors, "permission_friction": fr.permission_friction,
        },
        "tool_mix": dict(fr.tool_mix.most_common()),
        "repeated_bash": bash_rows,
        "broken_shell_patterns": [
            {"shape": s, "count": c, "example": fr.bash_examples.get(s, "")}
            for s, c in fr.broken_shell.most_common()
        ],
        "skill_usage": dict(fr.skill_usage.most_common()),
        "unused_skills": unused,
        "mcp_usage": dict(fr.mcp_usage.most_common()),
        "user_corrections": fr.corrections[:30],
        "long_tool_chains": sorted(
            [{"tool_count": c, "tools": t, "session": s} for c, t, s in fr.chains],
            key=lambda r: -r["tool_count"],
        )[:15],
    }


def human_summary(rep: dict) -> str:
    s, inst = rep["scope"], rep["instability"]
    lines = [
        f"reflect/miner: {s['transcripts']} transcripts, {s['sessions']} sessions, "
        f"{s['assistant_turns']} assistant turns "
        f"(excluded {len(s['excluded_reflect_sessions'])} reflect sessions)",
        f"  instability: retries={inst['api_retries']} errors={inst['api_errors']} "
        f"hook_errors={inst['hook_errors']} permission_friction={inst['permission_friction']}",
    ]
    if rep["broken_shell_patterns"]:
        lines.append("  broken-shell patterns: " + ", ".join(
            f"{r['shape']}×{r['count']}" for r in rep["broken_shell_patterns"][:5]))
    if rep["unused_skills"]:
        lines.append("  unused skills (GC watch): " + ", ".join(rep["unused_skills"]))
    if rep["user_corrections"]:
        lines.append(f"  user corrections: {len(rep['user_corrections'])}")
    lines.append("  top repeated bash: " + ", ".join(
        f"{r['shape']}×{r['count']}" for r in rep["repeated_bash"][:6]))
    return "\n".join(lines)


def load_watermark(state_path: str, fallback: datetime) -> datetime:
    try:
        with open(state_path) as fh:
            wm = parse_ts(json.load(fh).get("watermark"))
            return wm or fallback
    except (OSError, json.JSONDecodeError):
        return fallback


def save_watermark(state_path: str, watermark: str) -> None:
    os.makedirs(os.path.dirname(state_path), exist_ok=True)
    prev = {}
    try:
        with open(state_path) as fh:
            prev = json.load(fh)
    except (OSError, json.JSONDecodeError):
        pass
    prev["watermark"] = watermark
    prev["last_run"] = datetime.now(timezone.utc).isoformat()
    with open(state_path, "w") as fh:
        json.dump(prev, fh, indent=2)


def main() -> None:
    ap = argparse.ArgumentParser(description="Mine Claude Code transcripts for workflow friction.")
    ap.add_argument("--projects-dir", default=DEFAULT_PROJECTS)
    ap.add_argument("--state", default=DEFAULT_STATE)
    ap.add_argument("--outdir", default=DEFAULT_OUTDIR)
    ap.add_argument("--since-days", type=float, default=None,
                    help="Override the watermark: mine the last N days instead.")
    ap.add_argument("--exclude-session", default=os.environ.get("REFLECT_SESSION_ID"),
                    help="Session id of this reflect run, to exclude from mining.")
    ap.add_argument("--dry", action="store_true",
                    help="Print report to stdout; do not write files or advance the watermark.")
    args = ap.parse_args()

    now = datetime.now(timezone.utc)
    if args.since_days is not None:
        since = now - timedelta(days=args.since_days)
    else:
        since = load_watermark(args.state, fallback=now - timedelta(days=7))

    fr = mine(args.projects_dir, since, args.exclude_session)
    watermark_new = now.isoformat()
    rep = report(fr, since, watermark_new)

    print(human_summary(rep))
    if args.dry:
        print("\n--- friction.json (dry; not written) ---")
        print(json.dumps(rep, indent=2))
        return

    os.makedirs(args.outdir, exist_ok=True)
    out = os.path.join(args.outdir, f"friction-{now.date().isoformat()}.json")
    with open(out, "w") as fh:
        json.dump(rep, fh, indent=2)
    save_watermark(args.state, watermark_new)
    print(f"\nwrote {out}")
    print(f"advanced watermark → {watermark_new}")


if __name__ == "__main__":
    main()
