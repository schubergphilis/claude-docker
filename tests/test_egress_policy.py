# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""--api --egress-lock locks model traffic to ANTHROPIC_BASE_URL.

The endpoint checks run before container-runtime detection, so these cases
need no docker: an endpoint that passes stops at the invalid
CLAUDE_DOCKER_RUNTIME the helper sets.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"


def run(args, **env_extra):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("ANTHROPIC_", "CLAUDE_DOCKER_"))}
    env.update(ANTHROPIC_AUTH_TOKEN="sk-test", CLAUDE_DOCKER_RUNTIME="none", **env_extra)
    with tempfile.TemporaryDirectory() as ws:
        return subprocess.run(["bash", str(RUN_SH), *args, ws],
                              env=env, capture_output=True, text=True, timeout=30)


class Endpoint(unittest.TestCase):
    def assert_refused(self, needle, args=("--api", "--egress-lock"), **env):
        r = run(list(args), **env)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn(needle, r.stderr)

    def test_needs_api(self):
        self.assert_refused("--egress-lock needs --api", args=["--egress-lock"],
                            ANTHROPIC_BASE_URL="https://llm.example.eu")

    def test_base_url_required(self):
        self.assert_refused("--egress-lock needs ANTHROPIC_BASE_URL")

    def test_api_alone_skips_the_lock(self):
        # No ANTHROPIC_BASE_URL: the lock would refuse this, --api alone doesn't.
        r = run(["--api"])
        self.assertIn("CLAUDE_DOCKER_RUNTIME must be", r.stderr)

    def test_provider_endpoint_refused(self):
        for url in ("https://api.anthropic.com", "https://x.claude.ai/v1", "https://claude.com",
                    # Hostnames are case-insensitive, and so is squid's dstdomain.
                    "https://Api.Anthropic.com", "https://X.CLAUDE.AI/v1"):
            with self.subTest(url=url):
                self.assert_refused("points at one", ANTHROPIC_BASE_URL=url)

    def test_injection_refused(self):
        self.assert_refused("is not a valid hostname",
                            ANTHROPIC_BASE_URL="https://a.eu\nhttp_access allow all/")
        self.assert_refused("is not a valid hostname", ANTHROPIC_BASE_URL="https://a b.eu/")

    def test_invalid_port_refused(self):
        # The port is written into squid.conf, so it is validated like the host.
        for url in ("https://gw.example.eu:0", "https://gw.example.eu:65536",
                    "https://gw.example.eu:80a/v1", "https://gw.example.eu:123456"):
            with self.subTest(url=url):
                self.assert_refused("is not a port number", ANTHROPIC_BASE_URL=url)

    def test_gateway_passes(self):
        for url in ("https://llm.example.eu/v1", "https://u:p@10.1.2.3:8443", "https://notanthropic.com",
                    "http://litellm:4000", "https://gw.example.eu:443/v1"):
            with self.subTest(url=url):
                r = run(["--api", "--egress-lock"], ANTHROPIC_BASE_URL=url)
                self.assertIn("CLAUDE_DOCKER_RUNTIME must be", r.stderr)


if __name__ == "__main__":
    unittest.main()
