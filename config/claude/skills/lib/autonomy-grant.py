#!/usr/bin/env python3
"""autonomy-grant — the single source of truth for the lit autonomy grant.

[LAW:one-source-of-truth] every consumer (`/auto`, `next`, `address-pr-reviews`)
asks THIS for "is autonomy authorized for ticket X" and "what is still pending."
The grant predicate lives here once; no skill reimplements it, so the rule that
governs auto-merge can never drift between callers.

A *grant* is the active, bounded authorization Hunter issues via `/auto`: a
FROZEN set of ticket IDs the agent may merge-and-chain without a human gate.
Absence of a grant is the default and the safe direction — human-gated, the
agent stops at a green reviewed PR and waits for Hunter to merge.

The grant is a file because every ticket runs in a freshly /clear-ed context
(the bottle resets the pane): a fresh agent has amnesia, so authorization cannot
live in conversation — only on disk, where each new agent re-reads it. Keyed by
the lit `workspace_id` (per-repo, spans every worktree of that repo).

Eligibility (curated — e.g. the `auto-hold` lit label) is deliberately kept OUT
of this file [LAW:single-enforcer]: a stale label must never silently re-enable
autonomy. Only an explicit, current grant authorizes, and this file *is* that
grant. The two layers are separate so one can never quietly stand in for the
other.

Exit codes are a contract, not just 0/1:
  0  success / predicate true (authorized)
  1  predicate false (NOT authorized)
  2  usage error (argparse)
  3  no active grant for this workspace
  4  operation error (e.g. completing a ticket outside the grant scope)

A nonzero exit ALWAYS means "not authorized" to a consumer — so even an internal
error fails safe toward the human-gated default rather than toward auto-merge.
"""

import argparse
import json
import os
import subprocess
import sys
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone

DEFAULT_DIR = os.path.expanduser("~/.claude/lit-autonomy")

# Exit codes — see module docstring.
EXIT_OK = 0
EXIT_FALSE = 1
EXIT_NO_GRANT = 3
EXIT_OP_ERROR = 4


@dataclass
class Grant:
    """The active autonomy authorization for one lit workspace.

    `scope` is FROZEN at grant time: the set of ticket IDs Hunter approved for
    autonomous merge-and-chain. Tickets created after the grant are absent from
    it on purpose, so they are never auto-run without a fresh review. `completed`
    grows as the chain merges each ticket; `pending` is what authorization still
    covers. `excluded_ids` records the keep-human tickets at grant time — it is
    reporting metadata only (held tickets are simply never placed in `scope`),
    not an input to the predicate.
    """

    workspace_id: str
    granted_at: str
    scope: list = field(default_factory=list)
    excluded_ids: list = field(default_factory=list)
    completed: list = field(default_factory=list)
    mode: str = "until_empty"

    def pending(self):
        # Authorization that remains: the frozen scope minus what already
        # merged. Order follows scope so "next eligible" is deterministic.
        done = set(self.completed)
        return [t for t in self.scope if t not in done]

    def covers(self, ticket_id):
        return ticket_id in self.pending()


_REQUIRED_KEYS = ("workspace_id", "granted_at", "scope", "excluded_ids", "completed")


def _grant_from_dict(raw):
    missing = [k for k in _REQUIRED_KEYS if k not in raw]
    if missing:
        # [LAW:no-silent-failure] a malformed grant is corruption, not "no
        # grant" — surface it so it is fixed, never silently degraded.
        raise ValueError(f"grant file missing required keys: {missing}")
    return Grant(
        workspace_id=raw["workspace_id"],
        granted_at=raw["granted_at"],
        scope=list(raw["scope"]),
        excluded_ids=list(raw["excluded_ids"]),
        completed=list(raw["completed"]),
        mode=raw.get("mode", "until_empty"),
    )


def grant_path(directory, workspace_id):
    return os.path.join(directory, f"{workspace_id}.json")


def read_grant(directory, workspace_id):
    """Return the Grant for this workspace, or None if no grant file exists.

    A present-but-broken file raises — None means *no grant*, never *unreadable
    grant*. Conflating them would silently drop authorization (or worse, mask a
    bug behind the safe default and hide that the file needs repair).
    """
    path = grant_path(directory, workspace_id)
    if not os.path.exists(path):
        return None
    with open(path) as f:
        raw = json.load(f)
    grant = _grant_from_dict(raw)
    if grant.workspace_id != workspace_id:
        raise ValueError(
            f"grant file {path} is for workspace {grant.workspace_id!r}, "
            f"not {workspace_id!r}"
        )
    return grant


def write_grant(directory, grant):
    """Persist the grant atomically (temp file + rename) so a fresh agent never
    reads a half-written grant."""
    os.makedirs(directory, exist_ok=True)
    path = grant_path(directory, grant.workspace_id)
    tmp = path + ".tmp"
    with open(tmp, "w") as f:
        json.dump(asdict(grant), f, indent=2)
        f.write("\n")
    os.replace(tmp, path)
    return path


def resolve_workspace_id(explicit):
    """The grant key. Explicit override exists for testing on a scratch case;
    production resolves it from lit so the key is computed in exactly one way."""
    if explicit:
        return explicit
    proc = subprocess.run(
        ["lit", "workspace", "--json"], capture_output=True, text=True
    )
    if proc.returncode != 0:
        raise SystemExit(
            f"autonomy-grant: `lit workspace --json` failed: {proc.stderr.strip()}"
        )
    workspace_id = json.loads(proc.stdout).get("workspace_id")
    if not workspace_id:
        raise SystemExit("autonomy-grant: lit workspace returned no workspace_id")
    return workspace_id


def _parse_id_list(value):
    # Accept comma- and/or whitespace-separated IDs; drop blanks.
    if not value:
        return []
    return [tok for tok in value.replace(",", " ").split() if tok]


# --- subcommands ---------------------------------------------------------------


def cmd_grant(args, directory, workspace_id):
    scope = _parse_id_list(args.scope)
    excluded = _parse_id_list(args.exclude)
    if not scope:
        raise SystemExit("autonomy-grant: --scope must list at least one ticket id")
    overlap = sorted(set(scope) & set(excluded))
    if overlap:
        # scope (authorized) and excluded (held) are disjoint by definition;
        # an overlap is an incoherent grant. Fail at the write boundary so the
        # predicate downstream never has to reconcile the contradiction.
        raise SystemExit(
            f"autonomy-grant: tickets in both --scope and --exclude: {overlap}"
        )
    grant = Grant(
        workspace_id=workspace_id,
        granted_at=datetime.now(timezone.utc).isoformat(),
        scope=scope,
        excluded_ids=excluded,
        completed=[],
        mode="until_empty",
    )
    path = write_grant(directory, grant)
    print(f"autonomy grant written → {path}")
    print(f"  scope ({len(scope)} eligible): {' '.join(scope)}")
    if excluded:
        print(f"  held  ({len(excluded)} keep-human): {' '.join(excluded)}")
    return EXIT_OK


def cmd_status(args, directory, workspace_id):
    grant = read_grant(directory, workspace_id)
    if grant is None:
        if args.json:
            print("null")
        else:
            print(f"no active autonomy grant for workspace {workspace_id}")
        return EXIT_NO_GRANT
    if args.json:
        print(json.dumps(asdict(grant), indent=2))
        return EXIT_OK
    pending = grant.pending()
    print(f"active autonomy grant (workspace {workspace_id})")
    print(f"  granted_at: {grant.granted_at}")
    print(f"  mode:       {grant.mode}")
    print(f"  pending ({len(pending)}): {' '.join(pending) or '—'}")
    print(f"  completed ({len(grant.completed)}): {' '.join(grant.completed) or '—'}")
    print(f"  held ({len(grant.excluded_ids)}): {' '.join(grant.excluded_ids) or '—'}")
    return EXIT_OK


def cmd_authorized(args, directory, workspace_id):
    grant = read_grant(directory, workspace_id)
    if grant is None:
        print(
            f"not authorized: no active autonomy grant for workspace {workspace_id}",
            file=sys.stderr,
        )
        return EXIT_FALSE
    if grant.covers(args.ticket):
        return EXIT_OK
    if args.ticket in grant.completed:
        reason = "already completed under this grant"
    elif args.ticket in grant.scope:
        reason = "in scope but not pending"
    else:
        reason = "not in grant scope (created after the grant, or held keep-human)"
    print(f"not authorized: {args.ticket} {reason}", file=sys.stderr)
    return EXIT_FALSE


def cmd_pending(args, directory, workspace_id):
    grant = read_grant(directory, workspace_id)
    if grant is None:
        print(
            f"no active autonomy grant for workspace {workspace_id}", file=sys.stderr
        )
        return EXIT_NO_GRANT
    for ticket in grant.pending():
        print(ticket)
    return EXIT_OK


def cmd_complete(args, directory, workspace_id):
    grant = read_grant(directory, workspace_id)
    if grant is None:
        print(
            f"no active autonomy grant for workspace {workspace_id}", file=sys.stderr
        )
        return EXIT_NO_GRANT
    if args.ticket not in grant.scope:
        # Finalize only marks complete after `authorized` passed, so this is a
        # caller bug, not a normal state — fail loud rather than record a ghost.
        print(
            f"autonomy-grant: {args.ticket} is not in the grant scope; refusing "
            f"to record it complete",
            file=sys.stderr,
        )
        return EXIT_OP_ERROR
    if args.ticket not in grant.completed:
        grant.completed.append(args.ticket)
        write_grant(directory, grant)
    remaining = grant.pending()
    print(
        f"recorded {args.ticket} complete; {len(remaining)} eligible ticket(s) "
        f"remaining: {' '.join(remaining) or '—'}"
    )
    return EXIT_OK


def cmd_stop(args, directory, workspace_id):
    path = grant_path(directory, workspace_id)
    if os.path.exists(path):
        os.remove(path)
        print(f"autonomy grant retired (removed {path})")
    else:
        print(f"no active autonomy grant to stop for workspace {workspace_id}")
    return EXIT_OK


def build_parser():
    parser = argparse.ArgumentParser(
        prog="autonomy-grant",
        description="Single source of truth for the lit autonomy grant.",
    )
    parser.add_argument(
        "--dir",
        default=DEFAULT_DIR,
        help="grant directory (default: ~/.claude/lit-autonomy)",
    )
    parser.add_argument(
        "--workspace-id",
        default=None,
        help="override the lit workspace id (default: `lit workspace --json`)",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    p_grant = sub.add_parser("grant", help="write/replace the active grant")
    p_grant.add_argument("--scope", required=True, help="eligible ticket ids")
    p_grant.add_argument("--exclude", default="", help="held keep-human ticket ids")
    p_grant.set_defaults(func=cmd_grant)

    p_status = sub.add_parser("status", help="show the active grant")
    p_status.add_argument("--json", action="store_true", help="emit JSON")
    p_status.set_defaults(func=cmd_status)

    p_auth = sub.add_parser(
        "authorized", help="exit 0 if autonomy is authorized for a ticket, else 1"
    )
    p_auth.add_argument("ticket", help="ticket id")
    p_auth.set_defaults(func=cmd_authorized)

    p_pending = sub.add_parser("pending", help="list eligible-and-not-yet-done ids")
    p_pending.set_defaults(func=cmd_pending)

    p_complete = sub.add_parser("complete", help="record a ticket merged-and-chained")
    p_complete.add_argument("ticket", help="ticket id")
    p_complete.set_defaults(func=cmd_complete)

    p_stop = sub.add_parser("stop", help="retire the active grant")
    p_stop.set_defaults(func=cmd_stop)

    return parser


def main(argv=None):
    args = build_parser().parse_args(argv)
    workspace_id = resolve_workspace_id(args.workspace_id)
    return args.func(args, args.dir, workspace_id)


if __name__ == "__main__":
    sys.exit(main())
