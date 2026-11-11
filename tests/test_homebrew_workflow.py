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

The rewrite itself, scripts/bump-homebrew-formula.sh, runs here against a
copy of the formula with a stub curl: a wrong version comparison would move
Homebrew users backwards or skip every bump, and nothing else would notice.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import hashlib
import os
import re
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = ROOT / ".github" / "workflows"

STABLE_TEST = re.compile(r'\[\[ ! "\$\{TAG\}" =~ (\S+) \]\]')
FORMULA = ROOT / "Formula" / "claude-docker.rb"
BUMP = ROOT / "scripts" / "bump-homebrew-formula.sh"
SERVER, REPO = "https://github.com", "schubergphilis/claude-docker"

# Serves each archive as its own URL, so the expected checksum is that URL's.
CURL = """#!/bin/sh
for a; do url="$a"; done
[ -n "$CURL_FAIL" ] && exit 22
printf '%s' "$url"
"""


def job(text, name):
    """Return one top-level job of a workflow as its text, from its
    `  name:` line up to the next job key or the end of the file. A comment
    indented like a job key does not end the job."""
    match = re.search(rf"^  {name}:\n(.*?)(?=^  [A-Za-z_-]+:|\Z)", text, re.MULTILINE | re.DOTALL)
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
        # release.yml only drafts; a draft holding just the bump is not published.
        self.assertIn('title="chore(homebrew): claude-docker ${version}"', self.homebrew)

    def test_the_bump_reuses_only_its_own_pull_request(self):
        # --head matches a fork's branch of the same name too.
        lookup = next(l for l in self.homebrew.splitlines() if 'number="$(gh pr list' in l)
        self.assertIn("--base main", lookup)
        self.assertIn("select(.isCrossRepository | not)", lookup)

    def test_the_bump_runs_the_tested_script(self):
        self.assertIn('scripts/bump-homebrew-formula.sh "${TAG}"', self.homebrew)

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


class BumpScriptTests(unittest.TestCase):
    """Run scripts/bump-homebrew-formula.sh on a copy of the formula."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        (root / "Formula").mkdir()
        self.formula = root / "Formula" / "claude-docker.rb"
        shutil.copy(FORMULA, self.formula)
        stubs = root / "bin"
        stubs.mkdir()
        (stubs / "curl").write_text(CURL)
        (stubs / "curl").chmod(0o755)
        self.root = root
        self.env = {
            **os.environ,
            "PATH": f"{stubs}{os.pathsep}{os.environ['PATH']}",
            "GITHUB_SERVER_URL": SERVER,
            "GITHUB_REPOSITORY": REPO,
            "GITHUB_STEP_SUMMARY": str(root / "summary"),
        }

    def at(self, version):
        """Point the copy at `version`, as an earlier bump would have."""
        text = re.sub(r"/refs/tags/v[0-9.]+\.tar\.gz", f"/refs/tags/v{version}.tar.gz", self.formula.read_text())
        self.formula.write_text(text)

    def bump(self, tag, **env):
        return subprocess.run(
            [str(BUMP), tag], cwd=self.root, env={**self.env, **env}, capture_output=True, text=True
        )

    def test_a_newer_tag_moves_url_and_sha256(self):
        self.at("1.1.0")
        result = self.bump("v1.2.0")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1.1.0\n", "should print the version it moved from")
        url = f"{SERVER}/{REPO}/archive/refs/tags/v1.2.0.tar.gz"
        formula = self.formula.read_text()
        self.assertIn(f'  url "{url}"\n', formula)
        self.assertIn(f'  sha256 "{hashlib.sha256(url.encode()).hexdigest()}"\n', formula)
        self.assertEqual(formula.count("v1.1.0"), 0)

    def test_versions_compare_numerically(self):
        self.at("1.9.0")
        result = self.bump("v1.10.0")
        self.assertEqual(result.stdout, "1.9.0\n", "1.10.0 is newer than 1.9.0")
        self.assertIn("/refs/tags/v1.10.0.tar.gz", self.formula.read_text())

    def test_an_older_or_the_same_tag_leaves_the_formula(self):
        for current, tag in (("1.2.0", "v1.1.9"), ("1.10.0", "v1.9.0"), ("1.2.0", "v1.2.0")):
            with self.subTest(current=current, tag=tag):
                self.at(current)
                before = self.formula.read_text()
                result = self.bump(tag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout, "", "should print nothing when it leaves the formula")
                self.assertEqual(self.formula.read_text(), before)

    def test_an_unrecognised_formula_fails(self):
        self.formula.write_text(self.formula.read_text().replace("/refs/tags/", "/heads/"))
        result = self.bump("v9.0.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Formula not recognised", result.stderr)

    def test_a_failed_download_leaves_the_formula(self):
        before = self.formula.read_text()
        result = self.bump("v9.0.0", CURL_FAIL="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertEqual(self.formula.read_text(), before)


if __name__ == "__main__":
    unittest.main()
