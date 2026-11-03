# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Keep the Homebrew formula bump behind a published, stable release.

This repository is its own Homebrew tap. homebrew.yml opens the pull request
that moves Formula/claude-docker.rb to a tag. Two things keep a Homebrew user
off an image that is not there or not supported: docker.yml calls it only
after the publishing job, and homebrew.yml itself drops any tag that is not a
stable vX.Y.Z. Nothing else ties those together, so a reordered job or a
loosened pattern would ship a release candidate, or a tag with no image, to
`brew upgrade`.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

STABLE_TEST = re.compile(r'\[\[ ! "\$\{TAG\}" =~ (\S+) \]\]')
FORMULA = ROOT / "Formula" / "claude-docker.rb"


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
        bump = self.homebrew.find("- name: Open the pull request")
        self.assertNotEqual(check, -1, "homebrew.yml should check the image is published")
        self.assertLess(check, bump, "the image check should come before the bump")
        self.assertEqual(
            self.homebrew.count("if: steps.tag.outputs.stable == 'true'"),
            2,
            "both the checkout and the bump should wait for the tag check",
        )

    def test_the_bump_is_a_pull_request_that_does_not_release(self):
        self.assertIn("gh pr create --base main", self.homebrew)
        self.assertNotRegex(self.homebrew, r"HEAD:refs/heads/main\b", "never push to main")
        # auto-release cuts a version for feat, fix and perf; a bump must not.
        self.assertIn('title="chore(homebrew): claude-docker ${version}"', self.homebrew)

    def test_the_formula_names_a_stable_release_of_this_repository(self):
        formula = FORMULA.read_text()
        self.assertRegex(
            formula,
            r'(?m)^  url "https://github\.com/schubergphilis/claude-docker/archive/refs/tags/v\d+\.\d+\.\d+\.tar\.gz"$',
        )
        self.assertRegex(formula, r'(?m)^  sha256 "[0-9a-f]{64}"$')
        self.assertIn(
            'CLAUDE_DOCKER_IMAGE="${CLAUDE_DOCKER_IMAGE:-ghcr.io/schubergphilis/claude-docker:v#{version}}"',
            formula,
            "the launcher should default to the image of its own version and let the user override it",
        )

    def test_docker_calls_it_after_publishing(self):
        homebrew = job(self.docker, "homebrew")
        self.assertTrue(homebrew, "docker.yml should have a homebrew job")
        self.assertIn("needs: docker", homebrew)
        self.assertIn("if: startsWith(github.ref, 'refs/tags/v')", homebrew)
        self.assertIn("uses: ./.github/workflows/homebrew.yml", homebrew)
        self.assertIn("tag: ${{ github.ref_name }}", homebrew)

    def test_only_the_publishing_job_can_write_packages(self):
        self.assertIn("packages: write", job(self.docker, "docker"))
        self.assertNotIn("packages:", job(self.docker, "homebrew"))
        self.assertNotIn("packages:", self.homebrew)


if __name__ == "__main__":
    unittest.main()
