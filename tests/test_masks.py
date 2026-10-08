# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Pin the one tmpfs-mask rule no container test exercises: gh's three states.

The rest of the mask set is asserted in-container by the smoke suite
(`smoke/smoke.sh` drives `run.sh`; `assert-in-container.sh` checks the tmpfs
set under /root by equality). The smoke cells never pass `--gh`, and
`tests/gh-proxy-integration.sh` does not look at the mask, so the rule that
keeps `/root/.config/gh` masked while the auth-proxy sidecar is active is only
pinned here.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"


class GhMaskTest(unittest.TestCase):
    def test_gh_mask_keeps_its_three_state_logic(self):
        """It must stay ON while the auth proxy sidecar is active.

        The sidecar hands the container a placeholder token, so persisted login
        state is unnecessary, and leaving it readable would reintroduce a
        persisted in-container secret. Collapsing this to `[ $WITH_GH = 0 ]`
        would unmask it for every --gh run.
        """
        text = RUN_SH.read_text()
        self.assertRegex(
            text,
            r'\[ "\$WITH_GH_DIRECT" = "1" \]\s*&&\s*gh_config_unmask=1',
            "--gh-direct no longer unmasks the gh config dir",
        )
        self.assertRegex(
            text,
            r'\[ "\$WITH_GH" = "1" \]\s*&&\s*\[ "\$GH_SIDECAR_ACTIVE" = "0" \]'
            r'\s*&&\s*gh_config_unmask=1',
            "the gh unmask no longer requires the sidecar to be inactive — a "
            "--gh run with a sidecar would expose persisted login state",
        )
        self.assertRegex(
            text,
            r'\[ "\$gh_config_unmask" = "0" \]\s*&&\s*'
            r'MOUNT_ARGS\+=\("--tmpfs" "/root/.config/gh"\)',
            "the gh mask is no longer gated on gh_config_unmask",
        )


if __name__ == "__main__":
    unittest.main()
