# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Keep the PR and weekly grype gates identical to docker.yml's publish scan.

ci.yml and image-scan.yml run grype themselves so that a finding the publish
scan would fail on fails the PR first. That only holds while they run the same
scan-action commit as the mcvs-docker-action that docker.yml pins, on the same
targets and with the same policy. Nothing else ties those together: Dependabot
can move docker.yml's pin on its own, and the skew this gate closes reopens
silently.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"
GATED = ("ci.yml", "image-scan.yml")

# mcvs-docker-action commit pinned in docker.yml -> the anchore/scan-action
# commit its action.yml runs. When docker.yml's pin moves, look the new one up
# (`uses: anchore/scan-action@...` in that commit's action.yml), add it here and
# move the two gated workflows to it.
SCAN_ACTION_FOR_MCVS = {
    "c9dfc78bd277dcabbe8719db6e1fc58b2eb673e1": "27805bf3b4e84b4a5c980df22ed233c00390a439",  # v0.14.0
}

MCVS_USES = re.compile(r"uses: schubergphilis/mcvs-docker-action@([0-9a-f]{40})")
SCAN_USES = re.compile(r"uses: anchore/scan-action@([0-9a-f]{40})")


def grype_steps(text):
    """Return each anchore/scan-action step of a workflow as its text, from its
    `- name:` line up to the next step or the end of the file."""
    steps = re.split(r"\n(?=      - )", text)
    return [s.strip() for s in steps if SCAN_USES.search(s)]


def inputs(step):
    """Return a step's `with:` inputs as a dict of strings."""
    return dict(re.findall(r"^\s{10}([a-z-]+): (.+)$", step, re.MULTILINE))


class GrypeGateTests(unittest.TestCase):
    def setUp(self):
        self.steps = {f: grype_steps((WORKFLOWS / f).read_text()) for f in GATED}

    def test_scan_action_matches_the_published_pipeline(self):
        pins = MCVS_USES.findall((WORKFLOWS / "docker.yml").read_text())
        self.assertEqual(len(pins), 1, "docker.yml should pin mcvs-docker-action once")
        self.assertIn(
            pins[0],
            SCAN_ACTION_FOR_MCVS,
            "docker.yml's mcvs-docker-action pin moved: add its scan-action commit "
            "to SCAN_ACTION_FOR_MCVS and move ci.yml and image-scan.yml to it",
        )
        expected = SCAN_ACTION_FOR_MCVS[pins[0]]
        for name, steps in self.steps.items():
            for step in steps:
                self.assertEqual(SCAN_USES.search(step)[1], expected, name)

    def test_both_workflows_run_the_same_steps(self):
        self.assertEqual(self.steps["ci.yml"], self.steps["image-scan.yml"])

    def test_gate_covers_image_and_checkout_with_the_publish_policy(self):
        got = [inputs(s) for s in self.steps["ci.yml"]]
        self.assertEqual(
            sorted(i.get("image") or "path:" + i.get("path", "") for i in got),
            ["claude-docker:ci", "path:."],
        )
        for i in got:
            self.assertEqual(i.get("config"), ".grype.yaml")
            self.assertEqual(i.get("severity-cutoff"), "high")
            self.assertEqual(i.get("only-fixed"), "false")
            self.assertEqual(i.get("fail-build"), "true")


if __name__ == "__main__":
    unittest.main()
