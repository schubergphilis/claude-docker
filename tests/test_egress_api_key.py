# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""--egress-lock pre-approves ANTHROPIC_API_KEY in ~/.claude.json.

Without the approval, a fresh ~/.claude.json (new volume, --ephemeral) makes
Claude Code's onboarding run a connectivity check against api.anthropic.com
and platform.claude.com, which the lock refuses, and the session exits.

Sources entrypoint.sh and runs approve_api_key with ROOT_HOME pointed at a
temp dir (and `chown` stubbed: the test isn't root). Needs bash and jq.
Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ENTRYPOINT = Path(__file__).resolve().parent.parent / "entrypoint.sh"
KEY = "sk-ant-test-0123456789abcdefghijKLMNOPQRSTUV"
KEY_ID = KEY[-20:]


class ApproveKey(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = self.tmp.name
        self.cfg = Path(self.root, ".claude.json")

    def tearDown(self):
        self.tmp.cleanup()

    def run_block(self, lock="1", key=KEY):
        script = 'source "$1"; ROOT_HOME="$2"; chown() { :; }; approve_api_key'
        env = {"PATH": os.environ["PATH"], "CLAUDE_DOCKER_EGRESS_LOCK": lock,
               "ANTHROPIC_API_KEY": key}
        return subprocess.run(["bash", "-euo", "pipefail", "-c", script, "bash",
                               str(ENTRYPOINT), self.root],
                              env=env, capture_output=True, text=True, timeout=30)

    def assert_ok(self, r):
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stderr, "")
        self.assertEqual([p.name for p in Path(self.root).iterdir()], [".claude.json"])

    def test_fresh_volume_gets_the_key_approved(self):
        self.assert_ok(self.run_block())
        self.assertEqual(json.loads(self.cfg.read_text()),
                         {"customApiKeyResponses": {"rejected": [], "approved": [KEY_ID]}})
        self.assertEqual(self.cfg.stat().st_mode & 0o777, 0o600)

    def test_existing_config_is_kept_and_not_duplicated(self):
        self.cfg.write_text(json.dumps({
            "hasCompletedOnboarding": True, "theme": "dark",
            "customApiKeyResponses": {"approved": ["other-key-id"], "rejected": ["x"]}}))
        for _ in range(2):
            self.assert_ok(self.run_block())
        self.assertEqual(json.loads(self.cfg.read_text()), {
            "hasCompletedOnboarding": True, "theme": "dark",
            "customApiKeyResponses": {"approved": ["other-key-id", KEY_ID], "rejected": ["x"]}})

    def test_key_is_trimmed_like_claude_code_does(self):
        self.assert_ok(self.run_block(key=f"  {KEY}\n"))
        self.assertEqual(json.loads(self.cfg.read_text())["customApiKeyResponses"]["approved"],
                         [KEY_ID])

    def test_noop_without_lock_or_key(self):
        for lock, key in (("", KEY), ("1", "")):
            with self.subTest(lock=lock, key=key):
                r = self.run_block(lock=lock, key=key)
                self.assertEqual(r.returncode, 0, r.stderr)
                self.assertFalse(self.cfg.exists())

    def test_invalid_json_left_alone(self):
        self.cfg.write_text("{not json")
        r = self.run_block()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn("not valid JSON", r.stderr)
        self.assertEqual(self.cfg.read_text(), "{not json")
        self.assertEqual([p.name for p in Path(self.root).iterdir()], [".claude.json"])

    def test_symlink_not_followed(self):
        with tempfile.TemporaryDirectory() as other:
            target = Path(other, "secret.json")
            target.write_text('{"secret": 1}')
            for dest in (target, Path(other, "missing.json")):
                with self.subTest(dest=dest.name):
                    self.cfg.unlink(missing_ok=True)
                    self.cfg.symlink_to(dest)
                    r = self.run_block()
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertIn("not a regular file", r.stderr)
                    self.assertTrue(self.cfg.is_symlink())
                    self.assertEqual(target.read_text(), '{"secret": 1}')
                    self.assertFalse(Path(other, "missing.json").exists())


if __name__ == "__main__":
    unittest.main()
