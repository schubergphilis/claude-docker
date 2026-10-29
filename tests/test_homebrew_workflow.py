# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Keep the Homebrew formula bump behind a published, stable release.

homebrew.yml opens the pull request on schubergphilis/homebrew-tap that moves
the formula to a tag. Two things keep a Homebrew user off an image that is not
there or not supported: docker.yml calls it only after the publishing job, and
homebrew.yml itself drops any tag that is not a stable vX.Y.Z. Nothing else
ties those together, so a reordered job or a loosened pattern would ship a
release candidate, or a tag with no image, to `brew upgrade`.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

STABLE_TEST = re.compile(r'\[\[ ! "\$\{TAG\}" =~ (\S+) \]\]')
BUMP_USES = re.compile(r"uses: mislav/bump-homebrew-formula-action@(\S+) # (v\S+)")


def job(text, name):
    """Return one top-level job of a workflow as its text, from its
    `  name:` line up to the next job or the end of the file."""
    match = re.search(rf"^  {name}:\n(.*?)(?=^  \S|\Z)", text, re.MULTILINE | re.DOTALL)
    return match.group(1) if match else ""


class HomebrewWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.homebrew = (WORKFLOWS / "homebrew.yml").read_text()
        self.docker = (WORKFLOWS / "docker.yml").read_text()

    def test_only_stable_tags_go_on(self):
        patterns = STABLE_TEST.findall(self.homebrew)
        self.assertEqual(len(patterns), 1, "homebrew.yml should test the tag once")
        stable = re.compile(patterns[0])
        for tag in ("v1.2.3", "v0.4.0", "v10.20.30"):
            self.assertRegex(tag, stable)
        for tag in ("v1.2.3-rc.1", "v1.2.3-rc1", "v1.2", "1.2.3", "main", "v1.2.3\nv1.2.4"):
            self.assertNotRegex(tag, stable, f"{tag!r} must not reach Homebrew")

    def test_the_image_is_checked_before_the_bump(self):
        check = self.homebrew.find("docker buildx imagetools inspect")
        bump = self.homebrew.find("uses: mislav/bump-homebrew-formula-action@")
        self.assertNotEqual(check, -1, "homebrew.yml should check the image is published")
        self.assertLess(check, bump, "the image check should come before the bump")
        self.assertIn("if: steps.tag.outputs.stable == 'true'", self.homebrew)

    def test_the_bump_is_a_pull_request_on_the_tap(self):
        pins = BUMP_USES.findall(self.homebrew)
        self.assertEqual(len(pins), 1, "pin the bump action once, with a version comment")
        self.assertRegex(pins[0][0], r"^[0-9a-f]{40}$", "pin the bump action by commit SHA")
        self.assertIn("homebrew-tap: schubergphilis/homebrew-tap", self.homebrew)
        self.assertIn("create-pullrequest: true", self.homebrew)

    def test_docker_calls_it_after_publishing(self):
        homebrew = job(self.docker, "homebrew")
        self.assertTrue(homebrew, "docker.yml should have a homebrew job")
        self.assertIn("needs: docker", homebrew)
        self.assertIn("if: startsWith(github.ref, 'refs/tags/v')", homebrew)
        self.assertIn("uses: $/.github/workflows/homebrew.yml", homebrew)
        self.assertIn("tag: ${{ github.ref_name }}", homebrew)

    def test_only_the_publishing_job_can_write_packages(self):
        self.assertIn("packages: write", job(self.docker, "docker"))
        self.assertNotIn("packages: write", job(self.docker, "homebrew"))
        self.assertNotIn("write", self.homebrew)


if __name__ == "__main__":
    unittest.main()
