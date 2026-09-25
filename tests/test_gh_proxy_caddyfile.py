# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""The gh-proxy sidecar Caddyfile must reach disk exactly as written in run.sh.

Its `{$GH_PROXY_UPSTREAM_*}` and `{env.GH_PROXY_*}` references are resolved by
Caddy (config-load and per-request), never by the shell: the token must not be
baked into the staged file. That holds only while the heredoc delimiter stays
quoted.

Behaviour of the config itself is covered by tests/gh-proxy-integration.sh.
"""

import re
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


if __name__ == "__main__":
    unittest.main()
