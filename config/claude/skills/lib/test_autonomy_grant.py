#!/usr/bin/env python3
"""Behavior tests for autonomy-grant's lit workspace seam.

The contract under test: `lit workspace` text is the only surface. A caller
that still passes `--json` must fail here, because that flag is an unknown
flag and the grant check must not depend on it.
"""

import importlib.util
import os
import stat
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent / "autonomy-grant.py"

WORKSPACE_TEXT = """\
workspace_id: ws-test
issue_prefix: example
git_common_dir: /tmp/repo/.git
traces_dir: http://example.test:9/traces
"""


def load_module():
    spec = importlib.util.spec_from_file_location("autonomy_grant", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_fake_lit(directory, body):
    path = Path(directory) / "lit"
    path.write_text(body)
    path.chmod(path.stat().st_mode | stat.S_IEXEC)
    return path


class ParseWorkspaceText(unittest.TestCase):
    def test_reads_workspace_id_and_keeps_colons_in_values(self):
        fields = load_module().parse_workspace_text(WORKSPACE_TEXT)
        self.assertEqual(fields["workspace_id"], "ws-test")
        self.assertEqual(fields["traces_dir"], "http://example.test:9/traces")

    def test_rejects_a_non_field_line(self):
        with self.assertRaises(ValueError) as caught:
            load_module().parse_workspace_text("This is a preamble\n")
        self.assertIn("not 'key: value'", str(caught.exception))

    def test_rejects_empty_output(self):
        with self.assertRaises(ValueError):
            load_module().parse_workspace_text("\n")


class ResolveAgainstFakeLit(unittest.TestCase):
    def run_status(self, lit_body):
        with tempfile.TemporaryDirectory() as tmp:
            write_fake_lit(tmp, lit_body)
            grant_dir = Path(tmp) / "grants"
            env = os.environ.copy()
            env["PATH"] = tmp + os.pathsep + env.get("PATH", "")
            return subprocess.run(
                [str(SCRIPT), "--dir", str(grant_dir), "status"],
                capture_output=True,
                text=True,
                env=env,
            )

    def test_status_reads_text_and_refuses_json(self):
        # The fake fails closed on --json. A script that still passes the flag
        # cannot reach the "no grant" result this asserts.
        lit = textwrap.dedent(
            """\
            #!/bin/sh
            if [ "$1" = "workspace" ] && [ "$2" = "--json" ]; then
              echo "unknown flag: --json" >&2
              exit 2
            fi
            if [ "$1" = "workspace" ]; then
              printf '%s\\n' 'workspace_id: ws-test' 'issue_prefix: example'
              exit 0
            fi
            echo "unexpected: $*" >&2
            exit 2
            """
        )
        proc = self.run_status(lit)
        self.assertEqual(proc.returncode, 3, proc.stderr)
        self.assertIn("ws-test", proc.stdout)

    def test_malformed_workspace_text_fails_loud(self):
        lit = textwrap.dedent(
            """\
            #!/bin/sh
            echo "not a field"
            exit 0
            """
        )
        proc = self.run_status(lit)
        self.assertEqual(proc.returncode, 1)
        self.assertIn("not 'key: value'", proc.stderr)
        self.assertNotIn("no active autonomy grant", proc.stdout + proc.stderr)


if __name__ == "__main__":
    unittest.main()
