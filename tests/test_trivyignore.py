"""Enforce the .trivyignore entry contract: every accepted risk carries a
reason and an expiry.

Trivy enforces neither. In `pkg/result/ignore.go`, a line whose fields carry no
`exp:` token yields a zero `ExpiredAt`, which suppresses the finding
indefinitely — so without this test, `.trivyignore`'s mandatory expiry is a
comment nobody checks and an accepted risk becomes permanent silence.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import datetime
import re
import unittest
from pathlib import Path

TRIVYIGNORE = Path(__file__).resolve().parent.parent / ".trivyignore"

# The expiry shape is pinned here rather than delegated to
# datetime.date.fromisoformat, which also accepts `20261201` and `2026-W48-1`.
# Trivy parses with Go's "2006-01-02" and rejects both, then drops the entry —
# so a date this test accepted and Trivy did not would leave a finding blocking
# the gate while its author believes it is accepted.
ENTRY = re.compile(r"^(?P<id>[A-Za-z][A-Za-z0-9._-]*)\s+exp:(?P<exp>\d{4}-\d{2}-\d{2})$")


def violations(text):
    """Return one message per contract violation in a .trivyignore body.

    Fail-closed: a line this does not recognise is a violation, never a skip. A
    permissive parser cannot tell an unrecognised Trivy construct from a
    malformed entry, and so cannot enforce the contract at all.
    """
    found = []
    reason = None

    for lineno, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()

        # A blank line breaks the association, so a reason cannot drift onto an
        # entry paragraphs below it.
        if not line:
            reason = None
            continue

        if line.startswith("#"):
            reason = line.lstrip("#").strip() or None
            continue

        match = ENTRY.match(line)
        if not match:
            found.append(f"line {lineno}: {line!r} is not `<ID> exp:<yyyy-mm-dd>`")
            reason = None
            continue

        try:
            datetime.date.fromisoformat(match["exp"])
        except ValueError:
            found.append(
                f"line {lineno}: {match['id']} expiry {match['exp']!r} is not a real date"
            )

        if not reason:
            found.append(
                f"line {lineno}: {match['id']} has no reason comment directly above it"
            )

        # One reason covers one entry; a second entry needs its own.
        reason = None

    return found


HEADER = "# Accepted risk. Contract: reason comment, then `<ID> exp:<yyyy-mm-dd>`.\n"


class RealFileTests(unittest.TestCase):
    def test_committed_file_satisfies_the_contract(self):
        self.assertEqual(violations(TRIVYIGNORE.read_text()), [])


class ContractTests(unittest.TestCase):
    """Fixtures, not the real file: it has no entries yet, so passing on it
    alone would make a parser that accepts everything look green."""

    def test_header_only_passes(self):
        self.assertEqual(violations(HEADER), [])

    def test_well_formed_entry_passes(self):
        body = (
            HEADER + "\n# ubuntu has no fixed package yet; revisit at the next base bump\n"
            "CVE-2026-1234 exp:2026-12-01\n"
        )
        self.assertEqual(violations(body), [])

    def test_entry_with_no_expiry_is_rejected(self):
        body = HEADER + "\n# accepted\nCVE-2026-1234\n"
        found = violations(body)
        self.assertEqual(len(found), 1)
        self.assertIn("is not `<ID> exp:", found[0])

    def test_entry_with_an_unreal_date_is_rejected(self):
        body = HEADER + "\n# accepted\nCVE-2026-1234 exp:2026-13-45\n"
        self.assertIn("is not a real date", violations(body)[0])

    def test_entry_with_no_reason_is_rejected(self):
        body = HEADER + "\nCVE-2026-1234 exp:2026-12-01\n"
        self.assertIn("no reason comment", violations(body)[0])

    def test_date_shapes_trivy_cannot_parse_are_rejected(self):
        for exp in ("20261201", "2026-W48-1"):
            body = HEADER + f"\n# accepted\nCVE-2026-1234 exp:{exp}\n"
            self.assertEqual(len(violations(body)), 1, exp)

    def test_blank_line_breaks_the_reason_association(self):
        body = HEADER + "\n# reason\n\nCVE-2026-1234 exp:2026-12-01\n"
        self.assertIn("no reason comment", violations(body)[0])

    def test_one_reason_does_not_cover_a_second_entry(self):
        body = (
            HEADER + "\n# only covers the first\n"
            "CVE-2026-1111 exp:2026-12-01\nCVE-2026-2222 exp:2026-12-01\n"
        )
        found = violations(body)
        self.assertEqual(len(found), 1)
        self.assertIn("CVE-2026-2222", found[0])

    def test_unrecognised_construct_fails_closed(self):
        body = HEADER + "\n# reason\nCVE-2026-1234 exp:2026-12-01 paths:usr/lib\n"
        self.assertEqual(len(violations(body)), 1)


class ExpiryIsCheckedForPresenceNotFreshness(unittest.TestCase):
    """A lapsed acceptance is Trivy's to act on: it stops suppressing and the
    finding blocks the gate again. Failing here too would report one lapse as
    two unrelated red checks."""

    def test_long_past_expiry_is_accepted(self):
        body = HEADER + "\n# lapsed deliberately\nCVE-2020-1111 exp:2020-01-01\n"
        self.assertEqual(violations(body), [])

    def test_far_future_expiry_is_accepted(self):
        body = HEADER + "\n# accepted for a long time\nCVE-2026-1234 exp:2099-01-01\n"
        self.assertEqual(violations(body), [])


if __name__ == "__main__":
    unittest.main()
