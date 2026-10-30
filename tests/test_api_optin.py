# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""--api must fail closed without a gateway token, and keep it in the sidecar.

With only ANTHROPIC_BASE_URL set, Claude Code sends the volume's claude.ai
OAuth token to the gateway as its bearer, so run.sh refuses to start. The check
runs before container-runtime detection, so those cases need no docker.

With a token, --api hands the endpoint and credential to the auth-proxy
sidecar (both by bare name) and the agent container gets a sidecar base URL
plus placeholders; --api-direct forwards them into the agent as before. A stub
`docker` records both `run` invocations.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"


def run_api(extra_env, flag="--api"):
    env = {k: v for k, v in os.environ.items() if not k.startswith("ANTHROPIC_")}
    env.update(extra_env)
    with tempfile.TemporaryDirectory() as ws:
        return subprocess.run(
            ["bash", str(RUN_SH), flag, ws],
            env=env, capture_output=True, text=True, timeout=30,
        )


# The agent `run --rm` and the sidecar `run -d` each get their argv and the
# ANTHROPIC_* / API_PROXY_* values docker would read; readiness polls answer
# as a healthy sidecar would.
DOCKER = """#!/bin/sh
case "$1" in
  logs) echo '{"msg":"serving initial configuration"}'; exit 0 ;;
  ps) [ "$2" = "-q" ] && echo cid; exit 0 ;;
  inspect) echo 10.0.0.2; exit 0 ;;
  run) ;;
  *) exit 0 ;;
esac
[ "$2" = "-d" ] && who=sidecar || who=agent
printf '%s\\n' "$@" > "$STUB_LOG/$who-argv"
env | grep -E '^(ANTHROPIC_|API_PROXY_)' | sort > "$STUB_LOG/$who-env"
"""


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


class ApiProxied(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.bin, self.log, self.home = t / "bin", t / "log", t / "home"
        for d in (self.bin, self.log, self.home):
            d.mkdir()
        (self.bin / "docker").write_text(DOCKER)
        (self.bin / "docker").chmod(0o755)

    def tearDown(self):
        self.tmp.cleanup()

    def start(self, flag="--api", **extra):
        r = run_api({"PATH": f"{self.bin}:/usr/bin:/bin", "HOME": str(self.home),
                     "STUB_LOG": str(self.log), "CLAUDE_DOCKER_RUNTIME": "docker",
                     "ANTHROPIC_BASE_URL": "https://llm.internal/gw",
                     "ANTHROPIC_AUTH_TOKEN": "tok-secret", "ANTHROPIC_MODEL": "gw-opus", **extra}, flag)
        self.assertEqual(r.returncode, 0, r.stderr)
        read = lambda n: (self.log / n).read_text() if (self.log / n).exists() else ""  # noqa: E731
        return read("agent-argv").splitlines(), read("agent-env"), read("sidecar-argv").splitlines(), read("sidecar-env")

    def test_agent_gets_sidecar_url_and_placeholder(self):
        argv, _, side, side_env = self.start()
        self.assertIn("ANTHROPIC_BASE_URL=http://claude-docker-api-proxy:8080", argv)
        self.assertIn("ANTHROPIC_AUTH_TOKEN=claude-docker-proxy", argv)
        self.assertFalse(any(a.startswith("ANTHROPIC_API_KEY") for a in argv))
        self.assertIn("claude-docker-api-proxy:10.0.0.2", argv)
        # Other endpoint config still arrives by name.
        self.assertIn("ANTHROPIC_MODEL", argv)
        self.assertIn("API_PROXY_UPSTREAM=https://llm.internal", side_env)
        self.assertIn("API_PROXY_PREFIX=/gw", side_env)
        self.assertIn("API_PROXY_BEARER=Bearer tok-secret", side_env)
        for a in argv + side:
            self.assertNotIn("tok-secret", a)
            self.assertNotIn("llm.internal", a)

    def test_api_direct_forwards_by_name(self):
        argv, env, side, _ = self.start(flag="--api-direct")
        self.assertEqual(side, [])
        for name in ("ANTHROPIC_BASE_URL", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_MODEL"):
            self.assertIn(name, argv)
        self.assertIn("ANTHROPIC_AUTH_TOKEN=tok-secret", env)
        self.assertFalse(any("tok-secret" in a for a in argv))
        self.assertIn("api-direct", "".join(argv))


if __name__ == "__main__":
    unittest.main()
