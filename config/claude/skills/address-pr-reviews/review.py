#!/usr/bin/env python3
"""review.py — one-line CLI over the address-pr-reviews provider contract.

Replaces the per-call `PR_REVIEW_REPO_ROOT="$PWD" PYTHONPATH=<skill-dir> python3 -c '<5-line
program>'` incantation that SKILL.md currently asks agents to hand-assemble for every loop
step. Reflect cycle 52 counted 20 such programs across 4 sessions in one day, in three
different output formats for the same `fetch`.

Each subcommand maps 1:1 to one contract function (PROVIDER_CONTRACT.md) and prints that
function's return value as JSON on stdout. Errors go to stderr with exit 1 — the same
RuntimeError the contract already guarantees, message intact.

[LAW:one-source-of-truth] provider selection is still provider_loader.get(); this file adds
no second precedence chain. [LAW:no-silent-failure] nothing is caught except to re-raise as
exit 1 with the message intact; a capability that is False is reported as a value, never
silently skipped.

Usage (run from the PR's worktree, or with PR_REVIEW_REPO_ROOT set — unchanged):
    review.py provider                       # active provider + CAPABILITIES
    review.py check OWNER REPO               # setup_check; {"skipped":...} if cap False
    review.py trigger PR_URL                 # trigger;     {"skipped":...} if cap False
    review.py wait PR_URL                    # blocks; {status, conclusion, sha, url}
    review.py fetch PR_URL [--unresolved]    # {"findings": [...]}
    review.py resolve THREAD_ID              # {"thread_id": ..., "is_resolved": true}
    review.py --provider NAME <subcommand>   # pin a provider for this call

STATUS — installed by reflect cycle 60, NOT YET WIRED INTO SKILL.md. Executed 2026-09-29:
`provider` (grok_provider, caps printed) and `fetch --unresolved` against PR #10
({"findings": []}) both ran clean; trigger/wait/resolve/check are still read-verified only.
The interface assertions below were first checked against source:
  - provider_loader.get(name=None) accepts None and falls through env -> provider.json
    (provider_loader.py:27, _resolve_name's `if explicit:` guard)
  - CAPABILITIES keys "resolve"/"trigger"/"setup_check" are validated present by the
    loader before it returns (provider_loader.py:81), so caps[...] cannot KeyError
  - wait/fetch are validated to exist on the module (provider_loader.py:86)
  - fetch returns {"findings":[{... "is_resolved": bool ...}]} (PROVIDER_CONTRACT.md:75-95)
  - resolve returns {"thread_id":..., "is_resolved": True} (PROVIDER_CONTRACT.md:109)
Until SKILL.md is patched to call it, nothing calls this file; it is inert on disk and
`rm` is a complete undo.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent
if str(SKILL_DIR) not in sys.path:
    sys.path.insert(0, str(SKILL_DIR))

import provider_loader  # noqa: E402  (sibling import; path set above)


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="review.py", description=__doc__.split("\n\n")[0])
    ap.add_argument("--provider", help="pin a provider name for this call only")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("provider")
    c = sub.add_parser("check")
    c.add_argument("owner")
    c.add_argument("repo")
    t = sub.add_parser("trigger")
    t.add_argument("pr_url")
    w = sub.add_parser("wait")
    w.add_argument("pr_url")
    f = sub.add_parser("fetch")
    f.add_argument("pr_url")
    f.add_argument("--unresolved", action="store_true", help="only findings with is_resolved false")
    r = sub.add_parser("resolve")
    r.add_argument("thread_id")
    a = ap.parse_args(argv)

    p = provider_loader.get(a.provider)
    caps = p.CAPABILITIES

    if a.cmd == "provider":
        out = {"provider": p.__name__, "capabilities": caps}
    elif a.cmd == "check":
        out = (
            p.setup_check(a.owner, a.repo)
            if caps["setup_check"]
            else {"skipped": "setup_check", "reason": "provider declares setup_check False"}
        )
    elif a.cmd == "trigger":
        out = (
            p.trigger(a.pr_url)
            if caps["trigger"]
            else {"skipped": "trigger", "reason": "provider declares trigger False; it fires on push"}
        )
    elif a.cmd == "wait":
        out = p.wait(a.pr_url)
    elif a.cmd == "fetch":
        out = p.fetch(a.pr_url)
        if a.unresolved:
            out = {"findings": [x for x in out["findings"] if not x["is_resolved"]]}
    elif a.cmd == "resolve":
        if not caps["resolve"]:
            raise RuntimeError(
                "provider declares resolve False — acknowledge the finding in a reply instead"
            )
        out = p.resolve(a.thread_id)
    else:  # argparse makes this unreachable; kept so a new subcommand cannot fall through silently
        raise RuntimeError(f"unknown subcommand {a.cmd!r}")

    json.dump(out, sys.stdout, indent=2)
    print()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    # [LAW:no-silent-failure] gh failures carry their reason in stderr, which
    # CalledProcessError.__str__ drops — print it, the way local_review.cli_main does.
    except subprocess.CalledProcessError as e:
        print(f"ERROR: {(e.stderr or '').strip() or e}", file=sys.stderr)
        sys.exit(1)
    except (RuntimeError, ValueError) as e:  # JSONDecodeError is a ValueError
        print(f"ERROR: {e}", file=sys.stderr)
        sys.exit(1)
