# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""--api must fail closed without a gateway token.

With only ANTHROPIC_BASE_URL set, Claude Code sends the volume's claude.ai
OAuth token to the gateway as its bearer, so run.sh refuses to start. The check
runs before container-runtime detection, so these cases need no docker.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"


def run_api(extra_env):
    env = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_")}
    env.update(extra_env)
    with tempfile.TemporaryDirectory() as ws:
        return subprocess.run(
            ["bash", str(RUN_SH), "--api", ws],
            env=env, capture_output=True, text=True, timeout=30,
        )


class ApiRequiresToken(unittest.TestCase):
    def assert_refused(self, extra_env):
        r = run_api(extra_env)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn("--api needs ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY", r.stderr)

    def test_no_token(self):
        self.assert_refused({"ANTHROPIC_BASE_URL": "https://llm.invalid"})

    def test_empty_token(self):
        # A failed `$(helper)` yields an empty value; it must not count as set.
        self.assert_refused({"ANTHROPIC_BASE_URL": "https://llm.invalid",
                             "ANTHROPIC_AUTH_TOKEN": "", "ANTHROPIC_API_KEY": ""})


if __name__ == "__main__":
    unittest.main()
