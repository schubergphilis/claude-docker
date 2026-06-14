"""Unit tests for the pure helpers in update_pins.py.

No network, no Docker. The parent directory is put on sys.path so the script
imports as a normal module. Run with:
    python3 -m unittest discover -s claude-docker/tests
"""
import contextlib
import io
import sys
import unittest
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


if __name__ == "__main__":
    unittest.main()
