# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Unit tests for the pure helpers in update_pins.py.

No network, no Docker. The parent directory is put on sys.path so the script
imports as a normal module. Run with:
    python3 -m unittest discover -s tests
"""
import contextlib
import gzip
import io
import os
import re
import subprocess
import sys
import tempfile
import unittest
import unittest.mock
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import update_pins as up  # noqa: E402 — path set above


class TestParseDt(unittest.TestCase):
    def test_z_suffix_is_utc_aware(self):
        self.assertEqual(
            up.parse_dt("1970-01-01T00:00:00Z"),
            datetime(1970, 1, 1, tzinfo=timezone.utc),
        )

    def test_one_day_delta(self):
        self.assertEqual(
            up.parse_dt("1970-01-02T00:00:00Z") - up.parse_dt("1970-01-01T00:00:00Z"),
            timedelta(days=1),
        )

    def test_fractional_seconds_preserved(self):
        self.assertEqual(up.parse_dt("1970-01-01T00:00:01.500Z").microsecond, 500000)

    def test_naive_input_assumed_utc(self):
        self.assertEqual(up.parse_dt("1970-01-01T00:00:00").tzinfo, timezone.utc)


class TestVersionSelection(unittest.TestCase):
    def test_max_stable_is_version_not_lexical(self):
        self.assertEqual(up.max_stable(["1.2.0", "1.10.0", "1.9.0"]), "1.10.0")

    def test_max_stable_excludes_prereleases(self):
        self.assertEqual(up.max_stable(["1.9.0", "2.0.0-rc1", "2.0.0-beta"]), "1.9.0")

    def test_newest_within_major(self):
        self.assertEqual(
            up.newest_within_major(["10.33.2", "10.34.1", "11.5.3"], "10"), "10.34.1"
        )

    def test_newest_within_major_none_matches(self):
        self.assertEqual(up.newest_within_major(["10.33.2", "11.5.3"], "9"), "")


class TestMajorBump(unittest.TestCase):
    def test_true_across_major(self):
        self.assertTrue(up.is_major_bump("10.33.2", "11.0.0"))

    def test_false_within_major(self):
        self.assertFalse(up.is_major_bump("10.33.2", "10.34.0"))

    def test_false_when_no_current_pin(self):
        self.assertFalse(up.is_major_bump("", "1.0.0"))

    def test_major_of(self):
        self.assertEqual(up.major_of("10.33.2"), "10")


class TestParseArgsPin(unittest.TestCase):
    def _expect_exit(self, argv):
        with self.assertRaises(SystemExit), contextlib.redirect_stderr(io.StringIO()):
            up.parse_args(argv)

    def test_valid_pin_for_known_tool(self):
        _, overrides = up.parse_args(["--pin", "uv=0.12.3"])
        self.assertEqual(overrides, {"uv": "0.12.3"})

    def test_unknown_tool_rejected(self):
        self._expect_exit(["--pin", "pmpm=10.0.0"])  # typo for pnpm

    def test_same_tool_pinned_twice_rejected(self):
        self._expect_exit(["--pin", "uv=0.12.3", "--pin", "uv=0.12.4"])

    def test_pin_without_version_rejected(self):
        self._expect_exit(["--pin", "uv="])

    def test_pin_accepts_non_semver_versions(self):
        # the escape hatch must still allow calver / prereleases / build metadata
        for ver in ("2024.10.1", "0.12.0-rc.1", "1.2.3+build.5"):
            _, overrides = up.parse_args(["--pin", f"uv={ver}"])
            self.assertEqual(overrides, {"uv": ver})

    def test_pin_rejects_shell_or_url_metacharacters(self):
        for ver in ("1.2.3; rm -rf /", "1.2.3 4", "`id`", "1.2.3/../x", "a$(id)"):
            self._expect_exit(["--pin", f"uv={ver}"])


class TestSelectVersion(unittest.TestCase):
    """The soak / held / --block-major-bumps decision core, fed synthetic
    candidate lists (no network) against a fixed `now`."""

    NOW = datetime(2026, 6, 1, tzinfo=timezone.utc)
    SOAK = timedelta(days=7)

    def _iso(self, days_ago):
        return (self.NOW - timedelta(days=days_ago)).isoformat()

    def _select(self, cand_days, current, block_major=False):
        cand = [(v, self._iso(d)) for v, d in cand_days]
        return up.select_version(cand, current, self.SOAK, self.NOW, block_major)

    def test_newest_soaked_version_selected(self):
        r = self._select([("1.2.0", 20), ("1.3.0", 10)], current="1.2.0")
        self.assertEqual(r.version, "1.3.0")
        self.assertEqual(r.status, "UPDATE")
        self.assertEqual(r.held, "")
        self.assertEqual(r.blocked_major, "")
        self.assertEqual(r.age, "10d")

    def test_too_new_version_is_held(self):
        r = self._select([("1.3.0", 10), ("1.4.0", 3)], current="1.3.0")
        self.assertEqual(r.version, "1.3.0")
        self.assertEqual(r.status, "NOCHANGE")
        self.assertEqual(r.held, "1.4.0")

    def test_no_newer_version_is_nochange(self):
        r = self._select([("1.2.0", 20), ("1.3.0", 10)], current="1.3.0")
        self.assertEqual(r.version, "1.3.0")
        self.assertEqual(r.status, "NOCHANGE")
        self.assertEqual(r.held, "")

    def test_major_crossed_by_default(self):
        r = self._select([("10.33.2", 30), ("11.5.3", 9)], current="10.33.2")
        self.assertEqual(r.version, "11.5.3")
        self.assertEqual(r.status, "UPDATE")
        self.assertEqual(r.blocked_major, "")
        self.assertTrue(up.is_major_bump("10.33.2", r.version))

    def test_block_major_stays_within_current_major(self):
        r = self._select(
            [("10.33.2", 30), ("10.34.1", 15), ("11.5.3", 9)],
            current="10.33.2", block_major=True,
        )
        self.assertEqual(r.version, "10.34.1")
        self.assertEqual(r.status, "UPDATE")
        self.assertEqual(r.blocked_major, "11.5.3")

    def test_block_major_with_nothing_newer_in_major_keeps_current(self):
        r = self._select([("11.5.3", 9)], current="10.33.2", block_major=True)
        self.assertEqual(r.version, "10.33.2")
        self.assertEqual(r.status, "NOCHANGE")
        self.assertEqual(r.blocked_major, "11.5.3")

    def test_prereleases_excluded_from_selection(self):
        r = self._select([("1.9.0", 20), ("2.0.0-rc1", 10)], current="1.9.0")
        self.assertEqual(r.version, "1.9.0")
        self.assertEqual(r.status, "NOCHANGE")

    def test_prerelease_never_reported_as_held(self):
        r = self._select([("1.9.0", 20), ("2.0.0-rc1", 2)], current="1.9.0")
        self.assertEqual(r.version, "1.9.0")
        self.assertEqual(r.held, "")

    def test_nothing_soaked_raises(self):
        with self.assertRaises(RuntimeError):
            self._select([("1.0.0", 2)], current="")


class TestRedirectAuthStrip(unittest.TestCase):
    """The redirect handler must keep Authorization on a same-host redirect,
    drop it when the host changes, and refuse a non-https redirect target."""

    def _redirect(self, from_url, to_url):
        req = urllib.request.Request(
            from_url, headers={"Authorization": "Bearer t", "User-Agent": "x"}
        )
        return up._HTTPSOnlyRedirect().redirect_request(req, None, 302, "Found", {}, to_url)

    def _has_auth(self, new_req):
        return any(k.lower() == "authorization" for k in new_req.headers)

    def test_authorization_dropped_on_cross_host_redirect(self):
        new = self._redirect("https://api.github.com/x", "https://cdn.example.com/y")
        self.assertFalse(self._has_auth(new))

    def test_authorization_kept_on_same_host_redirect(self):
        new = self._redirect("https://api.github.com/x", "https://api.github.com/y")
        self.assertTrue(self._has_auth(new))

    def test_non_https_redirect_rejected(self):
        with self.assertRaises(urllib.error.URLError):
            self._redirect("https://api.github.com/x", "http://cdn.example.com/y")


class TestVersionVar(unittest.TestCase):
    """version_var() must derive the correct env-var name for each npm tool."""

    def test_claude_code(self):
        self.assertEqual(up.version_var("claude-code"), "CLAUDE_CODE_VERSION")

    def test_openspec(self):
        self.assertEqual(up.version_var("openspec"), "OPENSPEC_VERSION")

    def test_pnpm(self):
        self.assertEqual(up.version_var("pnpm"), "PNPM_VERSION")


class TestListNpmTools(unittest.TestCase):
    """--list-npm-tools / run_list_npm_tools(): TSV output, no network."""

    # The three npm tools expected, in TOOLS order.
    _NPM_NAMES = ["claude-code", "openspec", "pnpm"]

    def _capture_list(self):
        """Run run_list_npm_tools(), return (exit_code, stdout_lines)."""
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = up.run_list_npm_tools()
        return rc, buf.getvalue().splitlines()

    def test_exactly_three_npm_tools_emitted(self):
        rc, lines = self._capture_list()
        self.assertEqual(rc, 0)
        self.assertEqual(len(lines), 3)

    def test_tool_names_are_npm_tools_in_order(self):
        rc, lines = self._capture_list()
        self.assertEqual(rc, 0)
        names = [ln.split("\t")[0] for ln in lines]
        self.assertEqual(names, self._NPM_NAMES)

    def test_columns_are_correct(self):
        """Each row must have 5 tab-separated columns with expected values."""
        rc, lines = self._capture_list()
        self.assertEqual(rc, 0)
        for line in lines:
            cols = line.split("\t")
            self.assertEqual(len(cols), 5, f"expected 5 columns, got {len(cols)}: {line!r}")
            name, pkg, env_file, var, ver = cols
            self.assertEqual(env_file, f"{name}.env")
            self.assertEqual(var, up.version_var(name))
            self.assertTrue(ver, f"version must be non-empty for {name}")

    def test_convention_matches_reality_var_in_fragment(self):
        """version_var(name) must actually be a key in read_fragment(name) for
        each npm tool — guards against version_var() and fragment_lines() drifting."""
        for name in self._NPM_NAMES:
            frag = up.read_fragment(name)
            var = up.version_var(name)
            self.assertIn(
                var, frag,
                f"{var} not found in pins/{name}.env; version_var() and fragment_lines() have drifted",
            )

    def test_empty_version_exits_nonzero_without_partial_output(self):
        """If any tool has no pin, exit non-zero and emit nothing to stdout."""
        with unittest.mock.patch.object(up, "read_current", return_value=""):
            buf = io.StringIO()
            err_buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err_buf):
                rc = up.run_list_npm_tools()
            self.assertNotEqual(rc, 0)
            self.assertEqual(buf.getvalue(), "", "no partial output must appear on stdout")
            self.assertIn("::error::", err_buf.getvalue())


# One recorded sample per tool, carrying the real output shape with a sentinel
# version substituted. Sentinels, not live versions, so a pin bump doesn't
# rewrite this table — the shape is what's under test, and CI's runtime check is
# what proves the shape still matches reality.
SENTINEL = "9.8.7"
VERSION_OUTPUT_SAMPLES = {
    "claude-code": f"{SENTINEL} (Claude Code)",
    "openspec": SENTINEL,
    "pnpm": SENTINEL,
    "uv": f"uv {SENTINEL} (aarch64-unknown-linux-gnu)",
    "glab": f"glab {SENTINEL} (4d7c6cda7)",
    "tfenv": f"tfenv {SENTINEL}",
    "awscli": f"aws-cli/{SENTINEL} Python/3.14.6 Linux/6.8.0 exe/aarch64.ubuntu.26",
}

# Constructs Python's re accepts but bash's [[ =~ ]] does not. A rule using one
# would pass every test here and silently never match in CI.
PYTHON_ONLY_REGEX = re.compile(r"\\[dwsDWSbAZ]|\(\?|\*\?|\+\?")


class TestToolRegistry(unittest.TestCase):
    """Every Tool record must carry a usable probe and version_re."""

    def test_every_tool_has_a_probe_and_rule(self):
        for tool in up.TOOLS:
            self.assertTrue(tool.probe, f"{tool.name} has no probe")
            self.assertTrue(tool.version_re, f"{tool.name} has no version_re")

    def test_probe_is_plain_argv(self):
        """The probe is split on whitespace by the CI consumer, so it must
        survive that round-trip — no embedded, leading, or doubled spaces."""
        for tool in up.TOOLS:
            self.assertEqual(" ".join(tool.probe.split()), tool.probe,
                             f"{tool.name}: probe does not round-trip through whitespace splitting")

    def test_version_re_has_exactly_one_group(self):
        for tool in up.TOOLS:
            self.assertEqual(re.compile(tool.version_re).groups, 1,
                             f"{tool.name}: version_re must capture exactly one group")

    def test_version_re_stays_in_the_shared_subset(self):
        for tool in up.TOOLS:
            self.assertIsNone(PYTHON_ONLY_REGEX.search(tool.version_re),
                              f"{tool.name}: version_re uses a construct bash [[ =~ ]] cannot read")

    def test_every_tool_has_a_recorded_sample(self):
        self.assertEqual(sorted(VERSION_OUTPUT_SAMPLES), sorted(t.name for t in up.TOOLS))

    def test_rule_extracts_the_version_from_its_own_sample(self):
        for tool in up.TOOLS:
            m = re.search(tool.version_re, VERSION_OUTPUT_SAMPLES[tool.name])
            self.assertIsNotNone(m, f"{tool.name}: version_re did not match its recorded output")
            self.assertEqual(m.group(1), SENTINEL, f"{tool.name}: extracted the wrong field")

    def test_rule_rejects_a_different_version(self):
        """Guards against a rule that matches the shape but captures a constant
        field — e.g. awscli's Python/ or distro version instead of the CLI's."""
        for tool in up.TOOLS:
            mutated = VERSION_OUTPUT_SAMPLES[tool.name].replace(SENTINEL, "1.0.0", 1)
            m = re.search(tool.version_re, mutated)
            got = m.group(1) if m else None
            self.assertNotEqual(got, SENTINEL, f"{tool.name}: rule ignores the version it should read")


class TestListTools(unittest.TestCase):
    """--list-tools / run_list_tools(): TSV output, no network."""

    def _capture_list(self):
        buf = io.StringIO()
        with contextlib.redirect_stdout(buf):
            rc = up.run_list_tools()
        return rc, buf.getvalue().splitlines()

    def test_every_tool_emitted_in_registry_order(self):
        rc, lines = self._capture_list()
        self.assertEqual(rc, 0)
        self.assertEqual([ln.split("\t")[0] for ln in lines], [t.name for t in up.TOOLS])

    def test_columns_match_the_registry_and_the_fragments(self):
        rc, lines = self._capture_list()
        self.assertEqual(rc, 0)
        for line, tool in zip(lines, up.TOOLS):
            cols = line.split("\t")
            self.assertEqual(len(cols), 4, f"expected 4 columns, got {len(cols)}: {line!r}")
            name, probe, version_re, ver = cols
            self.assertEqual((name, probe, version_re), (tool.name, tool.probe, tool.version_re))
            self.assertEqual(ver, up.read_current(tool.name))
            self.assertTrue(ver, f"version must be non-empty for {name}")

    def test_empty_version_exits_nonzero_without_partial_output(self):
        with unittest.mock.patch.object(up, "read_current", return_value=""):
            buf = io.StringIO()
            err_buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err_buf):
                rc = up.run_list_tools()
            self.assertNotEqual(rc, 0)
            self.assertEqual(buf.getvalue(), "", "no partial output must appear on stdout")
            self.assertIn("::error::", err_buf.getvalue())


class TestSoakStatus(unittest.TestCase):
    """soak_status() is pure — no network, fixed NOW like TestSelectVersion."""

    NOW = datetime(2026, 6, 1, tzinfo=timezone.utc)
    SOAK = timedelta(days=7)

    def _iso(self, days_ago):
        return (self.NOW - timedelta(days=days_ago)).isoformat()

    def _cand(self, specs):
        """specs: [(version, days_ago), ...]"""
        return [(v, self._iso(d)) for v, d in specs]

    def test_soaked_returns_true(self):
        """A pinned version older than the soak window must pass."""
        cand = self._cand([("1.0.0", 10), ("1.1.0", 8)])
        ok, age_days, reason = up.soak_status("1.0.0", cand, self.SOAK, self.NOW)
        self.assertTrue(ok)
        self.assertEqual(age_days, 10)
        self.assertEqual(reason, "soaked")

    def test_inside_soak_returns_false(self):
        """A pinned version younger than the soak window must fail."""
        cand = self._cand([("1.0.0", 10), ("1.1.0", 3)])
        ok, age_days, reason = up.soak_status("1.1.0", cand, self.SOAK, self.NOW)
        self.assertFalse(ok)
        self.assertEqual(age_days, 3)
        self.assertEqual(reason, "inside soak window")

    def test_pinned_absent_fails_closed(self):
        """A pinned version not present in the live registry must fail (yanked/unpublished)."""
        cand = self._cand([("1.0.0", 10)])
        ok, age_days, reason = up.soak_status("9.9.9", cand, self.SOAK, self.NOW)
        self.assertFalse(ok)
        self.assertIsNone(age_days)
        self.assertIn("not in registry", reason)

    def test_exactly_at_soak_boundary_passes(self):
        """Exact age == soak (timedelta comparison uses >=) must pass."""
        cand = self._cand([("2.0.0", 7)])
        ok, age_days, reason = up.soak_status("2.0.0", cand, self.SOAK, self.NOW)
        self.assertTrue(ok)
        self.assertEqual(age_days, 7)

    def test_checks_pinned_version_not_newest(self):
        """soak_status must check the PINNED version's age, not the newest candidate.
        Regression: fail-open if it accidentally checks a newer, soaked candidate."""
        # pinned=1.0.0 (2 days old, inside soak), cand also has 1.1.0 (10 days, soaked)
        cand = self._cand([("1.0.0", 2), ("1.1.0", 10)])
        ok, _, _ = up.soak_status("1.0.0", cand, self.SOAK, self.NOW)
        self.assertFalse(ok, "must check 1.0.0's age (2d), not 1.1.0's (10d)")


class TestAudit(unittest.TestCase):
    """run_audit() — mocked candidates + now_utc, no network."""

    NOW = datetime(2026, 6, 1, tzinfo=timezone.utc)
    SOAK_DAYS = 7

    def _iso(self, days_ago):
        return (self.NOW - timedelta(days=days_ago)).isoformat()

    def _npm_tools(self):
        """Return the npm-backed Tool records only."""
        return [t for t in up.TOOLS if t.kind == "npm"]

    def _build_cand(self, pinned_version, age_days):
        """Build a minimal candidate list where pinned_version is age_days old."""
        return [(pinned_version, self._iso(age_days))]

    def test_all_soaked_exits_zero(self):
        """All npm tools passing the soak gate → exit 0."""
        npm_tools = self._npm_tools()

        def fake_candidates(kind, ref):
            # Find the pinned version for this ref by looking up the name.
            name = next(t.name for t in up.TOOLS if t.ref == ref and t.kind == "npm")
            pinned = up.read_current(name)
            return self._build_cand(pinned, 20)  # well soaked

        with unittest.mock.patch.object(up, "candidates", side_effect=fake_candidates), \
             unittest.mock.patch.object(up, "now_utc", return_value=self.NOW):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                rc = up.run_audit(self.SOAK_DAYS)
        self.assertEqual(rc, 0)

    def test_inside_soak_exits_nonzero(self):
        """Any npm tool inside the soak window → exit non-zero."""
        call_count = [0]

        def fake_candidates(kind, ref):
            call_count[0] += 1
            name = next(t.name for t in up.TOOLS if t.ref == ref and t.kind == "npm")
            pinned = up.read_current(name)
            # First tool is inside soak (3d); rest are soaked (20d).
            age = 3 if call_count[0] == 1 else 20
            return self._build_cand(pinned, age)

        with unittest.mock.patch.object(up, "candidates", side_effect=fake_candidates), \
             unittest.mock.patch.object(up, "now_utc", return_value=self.NOW):
            err_buf = io.StringIO()
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err_buf):
                rc = up.run_audit(self.SOAK_DAYS)
        self.assertNotEqual(rc, 0)
        self.assertIn("::error::", err_buf.getvalue())

    def test_candidates_raises_exits_nonzero(self):
        """A candidates() exception → fail-closed → exit non-zero."""
        def fake_candidates(kind, ref):
            raise RuntimeError("simulated registry failure")

        with unittest.mock.patch.object(up, "candidates", side_effect=fake_candidates), \
             unittest.mock.patch.object(up, "now_utc", return_value=self.NOW):
            err_buf = io.StringIO()
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err_buf):
                rc = up.run_audit(self.SOAK_DAYS)
        self.assertNotEqual(rc, 0)
        self.assertIn("::error::", err_buf.getvalue())

    def test_empty_pin_exits_nonzero_with_distinct_message(self):
        """A tool with no pinned version → fail-closed with a 'no pinned
        version' error (NOT a misleading yank/registry message), and without
        ever calling candidates() for it."""
        with unittest.mock.patch.object(up, "read_current", return_value=""), \
             unittest.mock.patch.object(
                 up, "candidates",
                 side_effect=AssertionError("candidates() must not be called for an empty pin")), \
             unittest.mock.patch.object(up, "now_utc", return_value=self.NOW):
            err_buf = io.StringIO()
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf), contextlib.redirect_stderr(err_buf):
                rc = up.run_audit(self.SOAK_DAYS)
        self.assertNotEqual(rc, 0)
        self.assertIn("no pinned version", err_buf.getvalue())


class TestBaseImageCodename(unittest.TestCase):
    """base_image_codename() is pure — it parses the FROM tag, no I/O."""

    def test_codename_tag(self):
        text = "FROM ubuntu:resolute-20260724.1@sha256:" + "a" * 64 + "\n"
        self.assertEqual(up.base_image_codename(text), "resolute")

    def test_version_number_tag_yields_empty(self):
        """`ubuntu:26.04` names no apt suite — degrade rather than emit '26.04'
        and let the caller query a dists/ path that cannot exist."""
        text = "FROM ubuntu:26.04@sha256:" + "a" * 64 + "\n"
        self.assertEqual(up.base_image_codename(text), "")

    def test_no_from_line_yields_empty(self):
        self.assertEqual(up.base_image_codename("# just a comment\n"), "")

    def test_real_dockerfile_resolves(self):
        """Guards against the committed Dockerfile drifting to a FROM form this
        parser can't read — which would silently mute the task reminder."""
        self.assertTrue(up.base_image_codename(up.DOCKERFILE.read_text()))


class TestTaskLatestPublished(unittest.TestCase):
    """task_latest_published() — mocked apt index bytes, no network."""

    @staticmethod
    def _stanza(package, version):
        return (
            f"Package: {package}\nVersion: {version}\n"
            f"Filename: pool/any-version/main/t/ta/{package}_{version}"
            f"/{package}_{version}_linux_amd64.deb\n\n"
        )

    @classmethod
    def _index(cls, *versions):
        """Build a gzipped Debian Packages index listing `versions` of task."""
        return gzip.compress(
            "".join(cls._stanza("task", v) for v in versions).encode()
        )

    @classmethod
    def _mixed_index(cls, *stanzas):
        """Build a gzipped index from explicit (package, version) pairs."""
        return gzip.compress(
            "".join(cls._stanza(p, v) for p, v in stanzas).encode()
        )

    def _resolve(self, payload, codename="resolute"):
        with unittest.mock.patch.object(up, "http_bytes", return_value=payload):
            return up.task_latest_published(codename)

    def test_newest_version_resolved(self):
        self.assertEqual(self._resolve(self._index("3.53.1", "3.52.0", "3.51.1")), "3.53.1")

    def test_order_in_index_does_not_matter(self):
        """The index happens to be newest-first today; ordering must not be relied on."""
        self.assertEqual(self._resolve(self._index("3.46.4", "3.53.1", "3.50.0")), "3.53.1")

    def test_numeric_not_lexical_ordering(self):
        self.assertEqual(self._resolve(self._index("3.9.0", "3.53.1")), "3.53.1")

    def test_prerelease_ignored(self):
        self.assertEqual(self._resolve(self._index("3.53.1", "3.54.0-beta.1")), "3.53.1")

    def test_foreign_package_versions_ignored(self):
        """The repo serves only `task` today, so nothing else would catch a
        version scraped from a sibling package's stanza — and a version of some
        other package is exactly what `apt-get install task=<v>` cannot resolve."""
        self.assertEqual(
            self._resolve(self._mixed_index(
                ("task", "3.53.1"),
                ("taskfile-docs", "9.99.9"),
                ("task-completion", "8.0.0"),
            )),
            "3.53.1",
        )

    def test_index_without_task_yields_empty(self):
        """No `task` stanza at all must read as unresolvable, not as the newest
        version of whatever else the index happens to list."""
        self.assertEqual(
            self._resolve(self._mixed_index(("taskfile-docs", "9.99.9"))), ""
        )

    def test_field_order_within_a_stanza_does_not_matter(self):
        payload = gzip.compress(
            b"Version: 3.53.1\nPackage: task\n\n"
            b"Version: 9.99.9\nPackage: taskfile-docs\n\n"
        )
        self.assertEqual(self._resolve(payload), "3.53.1")

    def test_oversize_index_yields_empty(self):
        """Decompression of third-party bytes is bounded: `except Exception`
        cannot catch an OOM kill, so the bomb case has to degrade instead."""
        bomb = gzip.compress(b"Package: task\nVersion: 3.53.1\n\n" + b"#" * (2 << 20))
        self.assertLess(len(bomb), 1 << 20, "fixture must be small compressed")
        self.assertEqual(self._resolve(bomb), "")

    def test_empty_index_yields_empty(self):
        self.assertEqual(self._resolve(gzip.compress(b"")), "")

    def test_garbage_payload_yields_empty(self):
        """Not gzip at all → the decompress error is swallowed, not raised."""
        self.assertEqual(self._resolve(b"this is not gzip"), "")

    def test_empty_codename_skips_the_fetch(self):
        """With no suite there is no URL to build, so no request may be made."""
        with unittest.mock.patch.object(
            up, "http_bytes",
            side_effect=AssertionError("http_bytes must not be called without a codename"),
        ):
            self.assertEqual(up.task_latest_published(""), "")

    def test_network_failure_degrades(self):
        with unittest.mock.patch.object(
            up, "http_bytes", side_effect=urllib.error.URLError("simulated outage")
        ):
            self.assertEqual(up.task_latest_published("resolute"), "")

    def test_url_targets_the_derived_suite(self):
        seen = []

        def fake_http_bytes(url, headers=None):
            seen.append(url)
            return self._index("3.53.1")

        with unittest.mock.patch.object(up, "http_bytes", side_effect=fake_http_bytes):
            up.task_latest_published("noble")
        self.assertEqual(len(seen), 1)
        self.assertIn("/dists/noble/", seen[0])
        self.assertTrue(seen[0].startswith("https://"))


class TestPrintReminders(unittest.TestCase):
    """print_reminders() output — every upstream resolver mocked, no network."""

    def _capture(self, task_cur, codename="resolute"):
        with unittest.mock.patch.object(up, "task_latest_published", return_value=task_cur), \
             unittest.mock.patch.object(up, "base_image_codename", return_value=codename), \
             unittest.mock.patch.object(up, "go_latest_stable", return_value=""), \
             unittest.mock.patch.object(up, "ubuntu_current_digest", return_value=""):
            buf = io.StringIO()
            with contextlib.redirect_stdout(buf):
                up.print_reminders()
        return buf.getvalue()

    def _task_line(self, out):
        return next(ln for ln in out.splitlines() if " task " in ln)

    def test_drift_names_both_versions(self):
        line = self._task_line(self._capture("9.99.9"))
        self.assertIn("9.99.9", line)
        self.assertIn("DIFFERS", line)
        self.assertIn("TASK_VERSION", line)

    def test_drift_names_the_suite(self):
        """The operator most likely to act on the line gets the suite named too —
        the other three branches all say which suite they spoke to."""
        line = self._task_line(self._capture("9.99.9", codename="noble"))
        self.assertIn("noble", line)

    def test_match_reports_no_action(self):
        pinned = re.search(
            r"^ARG TASK_VERSION=(\S+)", up.DOCKERFILE.read_text(), re.MULTILINE
        ).group(1)
        line = self._task_line(self._capture(pinned))
        self.assertIn(pinned, line)
        self.assertIn("matches", line)
        self.assertNotIn("DIFFERS", line)

    def test_unresolved_names_the_suite(self):
        """An outage must read as an outage against a named suite."""
        line = self._task_line(self._capture("", codename="noble"))
        self.assertIn("could not resolve", line)
        self.assertIn("noble", line)

    def test_underivable_suite_is_distinct_from_an_outage(self):
        line = self._task_line(self._capture("", codename=""))
        self.assertIn("could not derive", line)

    def test_codename_and_digest_come_from_one_from_line(self):
        """A second `FROM ubuntu` must not split the two reminders: the suite the
        task line queries has to be the one on the base-image line whose digest
        the same run reports as pinned."""
        seen = []
        dockerfile = (
            f"FROM ubuntu:jammy-20240101@sha256:{'a' * 64} AS build\n"
            "ARG TASK_VERSION=3.53.1\n"
            f"FROM ubuntu:resolute-20260724.1@sha256:{'b' * 64}\n"
        )
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "Dockerfile"
            path.write_text(dockerfile)
            with unittest.mock.patch.object(up, "DOCKERFILE", path), \
                 unittest.mock.patch.object(
                     up, "task_latest_published",
                     side_effect=lambda c: (seen.append(c), "")[1]), \
                 unittest.mock.patch.object(up, "go_latest_stable", return_value=""), \
                 unittest.mock.patch.object(up, "ubuntu_current_digest", return_value=""):
                buf = io.StringIO()
                with contextlib.redirect_stdout(buf):
                    up.print_reminders()
        out = buf.getvalue()
        self.assertEqual(seen, ["resolute"])
        self.assertIn(f"sha256:{'b' * 12}", out)
        self.assertNotIn("a" * 12, out)

    def test_reminder_block_covers_every_manual_pin(self):
        out = self._capture("3.53.1")
        for pin in ("nodejs", "task", "go", "ubuntu base"):
            self.assertIn(pin, out, f"{pin} missing from the manual-pin reminder block")


class TestCIVersionCheckStep(unittest.TestCase):
    """Runs the real shell from ci.yml's runtime version check against a stub
    `docker`. Nothing else covers this script: action-shellcheck scans .sh files
    and shebang scripts, not `run:` blocks embedded in workflow YAML."""

    WORKFLOW = Path(__file__).resolve().parent.parent / ".github/workflows/ci.yml"
    STEP_NAME = "Smoke test — every pinned CLI reports its pinned version"

    @classmethod
    def setUpClass(cls):
        cls.script = cls._extract_run_block()

    @classmethod
    def _extract_run_block(cls):
        """Pull the step's `run: |` body out of the workflow and dedent it."""
        lines = cls.WORKFLOW.read_text().splitlines()
        start = next(i for i, ln in enumerate(lines) if cls.STEP_NAME in ln)
        run_at = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
        body_indent = len(lines[run_at + 1]) - len(lines[run_at + 1].lstrip())
        body = []
        for ln in lines[run_at + 1:]:
            if ln.strip() and len(ln) - len(ln.lstrip()) < body_indent:
                break
            body.append(ln[body_indent:] if ln.strip() else "")
        return "\n".join(body)

    def _run(self, overrides=None):
        """Execute the step with a stub docker whose per-tool output comes from
        the recorded samples, with `overrides` replacing chosen tools."""
        overrides = overrides or {}
        rows = []
        for tool in up.TOOLS:
            exe = tool.probe.split()[0]
            rc, out = overrides.get(
                tool.name,
                (0, VERSION_OUTPUT_SAMPLES[tool.name].replace(SENTINEL, up.read_current(tool.name))),
            )
            rows.append(f"{exe}\t{rc}\t{out}")

        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            fixture = tmp / "fixture.tsv"
            fixture.write_text("\n".join(rows) + "\n")
            docker = tmp / "docker"
            docker.write_text(
                "#!/usr/bin/env bash\n"
                'exe="$4"\n'
                'while IFS=$\'\\t\' read -r e rc out; do\n'
                '  if [ "$e" = "$exe" ]; then\n'
                '    [ -n "$out" ] && printf \'%s\\n\' "$out"\n'
                '    exit "$rc"\n'
                "  fi\n"
                'done < "$DOCKER_FIXTURE"\n'
                "exit 127\n"
            )
            docker.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{tmp}{os.pathsep}{os.environ['PATH']}",
                "DOCKER_FIXTURE": str(fixture),
            }
            return subprocess.run(
                ["bash", "-c", self.script], cwd=str(self.WORKFLOW.parents[2]),
                env=env, capture_output=True, text=True,
            )

    def test_all_tools_matching_passes_and_logs_every_tool(self):
        res = self._run()
        self.assertEqual(res.returncode, 0, res.stdout + res.stderr)
        for tool in up.TOOLS:
            self.assertIn(f"PASS  {tool.name}", res.stdout)
            self.assertIn(f"pinned={up.read_current(tool.name)}", res.stdout)

    def test_unrunnable_tool_fails_without_skipping_later_tools(self):
        res = self._run({"openspec": (1, "")})
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("FAIL  openspec", res.stdout)
        self.assertIn("<probe failed>", res.stdout)
        self.assertIn("PASS  awscli", res.stdout)  # last tool still probed

    def test_unreadable_version_fails_without_skipping_later_tools(self):
        res = self._run({"openspec": (0, "command not found: openspec")})
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("FAIL  openspec", res.stdout)
        self.assertIn("PASS  awscli", res.stdout)

    def test_mismatching_version_fails_without_skipping_later_tools(self):
        res = self._run({"openspec": (0, "0.0.1")})
        self.assertNotEqual(res.returncode, 0)
        self.assertIn("FAIL  openspec", res.stdout)
        self.assertIn("reported=0.0.1", res.stdout)
        self.assertIn("PASS  awscli", res.stdout)

    def test_every_failing_tool_is_reported_in_one_run(self):
        res = self._run({"openspec": (0, "0.0.1"), "uv": (1, ""), "tfenv": (0, "junk")})
        self.assertNotEqual(res.returncode, 0)
        for name in ("openspec", "uv", "tfenv"):
            self.assertIn(f"FAIL  {name}", res.stdout)
        self.assertIn("PASS  awscli", res.stdout)

    def test_failure_emits_a_github_error_annotation(self):
        res = self._run({"pnpm": (0, "0.0.1")})
        self.assertIn("::error::pnpm:", res.stdout)

    def test_a_failing_tool_listing_aborts_before_verifying_anything(self):
        """--list-tools is fail-closed; the step must inherit that rather than
        loop over an empty list and report success having checked nothing."""
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            py = tmp / "python3"
            py.write_text("#!/usr/bin/env bash\nexit 1\n")
            py.chmod(0o755)
            env = {**os.environ, "PATH": f"{tmp}{os.pathsep}{os.environ['PATH']}"}
            res = subprocess.run(
                ["bash", "-c", self.script], cwd=str(self.WORKFLOW.parents[2]),
                env=env, capture_output=True, text=True,
            )
        self.assertNotEqual(res.returncode, 0)
        self.assertNotIn("PASS", res.stdout)


if __name__ == "__main__":
    unittest.main()
