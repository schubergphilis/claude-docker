# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""The gh-proxy sidecar Caddyfile must reach disk exactly as written in run.sh.

Its `{$GH_PROXY_UPSTREAM_*}` and `{env.GH_PROXY_*}` references are resolved by
Caddy (config-load and per-request), never by the shell: the token must not be
baked into the staged file. That holds only while the heredoc delimiter stays
quoted. This runs the heredoc through bash with those variables set and asserts
the output is the literal body, byte for byte.

Behaviour of the config itself is covered by tests/gh-proxy-integration.sh.
"""

import os
import re
import subprocess
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"
HEREDOC = re.compile(
    r"^[ \t]*cat <<(\S+) >\"\$stage/gh-proxy/Caddyfile\"\n(.*?\n)(\w+)\n",
    re.S | re.M,
)


class GhProxyCaddyfileTest(unittest.TestCase):
    def test_caddyfile_is_written_verbatim_for_any_env(self):
        m = HEREDOC.search(RUN_SH.read_text())
        self.assertIsNotNone(m, "Caddyfile heredoc not found in run.sh")
        delim, body, end = m.groups()
        self.assertEqual(delim, f"'{end}'", "heredoc delimiter must stay single-quoted")
        self.assertIn("{env.GH_PROXY_BEARER}", body)

        env = {
            "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
            "GH_PROXY_UPSTREAM_GITHUB": "http://mock",
            "GH_PROXY_BASIC": "Basic LEAK",
            "GH_PROXY_BEARER": "Bearer LEAK",
            "GH_HOST_TOKEN": "LEAK",
        }
        script = m.group(0).lstrip().replace(' >"$stage/gh-proxy/Caddyfile"', "", 1)
        out = subprocess.run(
            ["bash", "-c", script], env=env, capture_output=True, text=True, check=True
        ).stdout
        self.assertEqual(out, body)


if __name__ == "__main__":
    unittest.main()
