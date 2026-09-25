# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Drive run.sh with stub `docker` and `op` to pin op:// resolution.

A forwarded credential var holding an op:// reference must be resolved on the
host and forwarded by bare name; a missing `op` or a failed read must exit 1
without launching the container or printing the reference or the secret.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"
REF = "op://Private/GitLab/token"
SECRET = "glpat-resolved-secret"

# Records `run` invocations: argv plus the value docker would read for
# GITLAB_TOKEN. Every other subcommand (stale-sidecar sweep) is a silent no-op.
DOCKER = """#!/bin/sh
[ "$1" = run ] || exit 0
printf '%s\\n' "$@" > "$STUB_LOG/argv"
printf '%s' "${GITLAB_TOKEN:-}" > "$STUB_LOG/token"
"""
OP = f"""#!/bin/sh
[ "$1" = read ] && [ "$2" = "{REF}" ] && {{ echo "{SECRET}"; exit 0; }}
echo "no item at $2" >&2; exit 1
"""


class OpReferenceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.bin, self.log, self.home, self.ws = (t / d for d in ("bin", "log", "home", "ws"))
        for d in (self.bin, self.log, self.home, self.ws):
            d.mkdir()
        self._stub("docker", DOCKER)

    def tearDown(self):
        self.tmp.cleanup()

    def _stub(self, name, body):
        p = self.bin / name
        p.write_text(body)
        p.chmod(0o755)

    def _run(self, token):
        env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "STUB_LOG": str(self.log),
            "CLAUDE_DOCKER_RUNTIME": "docker",
            "GITLAB_TOKEN": token,
        }
        return subprocess.run(
            ["bash", str(RUN_SH), "--glab", str(self.ws)],
            env=env, capture_output=True, text=True, timeout=60,
        )

    def test_reference_resolved_and_forwarded_by_name(self):
        self._stub("op", OP)
        r = self._run(REF)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.log / "token").read_text(), SECRET)
        argv = (self.log / "argv").read_text().splitlines()
        self.assertIn("GITLAB_TOKEN", argv)
        self.assertFalse(any(SECRET in a or REF in a for a in argv))

    def test_plain_value_untouched(self):
        r = self._run("glpat-plain")
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.log / "token").read_text(), "glpat-plain")

    def _assert_fails_closed(self, r):
        self.assertEqual(r.returncode, 1)
        self.assertIn("GITLAB_TOKEN", r.stderr)
        self.assertNotIn("Private/", r.stderr)
        self.assertNotIn(SECRET, r.stderr)
        self.assertFalse((self.log / "argv").exists(), "container launched")

    def test_missing_op_exits(self):
        self._assert_fails_closed(self._run(REF))

    def test_failed_read_exits(self):
        self._stub("op", OP)
        self._assert_fails_closed(self._run("op://Private/Missing/token"))


if __name__ == "__main__":
    unittest.main()
