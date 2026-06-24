"""Unit tests for the pure helpers in update_pins.py.

No network, no Docker. The parent directory is put on sys.path so the script
imports as a normal module. Run with:
    python3 -m unittest discover -s claude-docker/tests
"""
import contextlib
import io
import sys
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
        """Return [(name, kind, ref), ...] for npm tools only."""
        return [(n, k, r) for n, k, r in up.TOOLS if k == "npm"]

    def _build_cand(self, pinned_version, age_days):
        """Build a minimal candidate list where pinned_version is age_days old."""
        return [(pinned_version, self._iso(age_days))]

    def test_all_soaked_exits_zero(self):
        """All npm tools passing the soak gate → exit 0."""
        npm_tools = self._npm_tools()

        def fake_candidates(kind, ref):
            # Find the pinned version for this ref by looking up the name.
            name = next(n for n, k, r in up.TOOLS if r == ref and k == "npm")
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
            name = next(n for n, k, r in up.TOOLS if r == ref and k == "npm")
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


if __name__ == "__main__":
    unittest.main()
