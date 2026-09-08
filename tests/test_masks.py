# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Pin the tmpfs mask set that enforces the credential opt-in boundary.

The masks in `run.sh` are the entire mechanism keeping one session's persisted
credential state out of the next session's reach. `/root` and `/root/.claude`
are named volumes, mounted read-write and shared by every container, so a
credential path under them that carries no mask persists after the session that
wrote it and is readable by a later session that opted into nothing.

Nothing tested that set before this file. The smoke suite looks like it does,
but `smoke/smoke.sh` re-implements the mask list rather than invoking `run.sh` —
its own comment says "mirrors run.sh" — so a mask missing from `run.sh` cannot
fail the smoke suite, because the harness would simply not add it either. That
is how `/root/.aws` stayed off the list while `external-cli-tools/spec.md`
asserted it was masked.

This test therefore reads `run.sh` itself, and separately asserts the mirror
still matches it, since the drifting mirror is what made the gap invisible.

Fail-closed: the mask set is asserted by equality, not containment, so a mask
added without a spec delta and a test update fails here rather than shipping
unreviewed.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_SH = ROOT / "run.sh"
SMOKE_SH = ROOT / "smoke" / "smoke.sh"

# Every path run.sh is expected to mask, mapped to the shell variable that
# decides it. Equality-checked, so this dict is the reviewed mask set.
EXPECTED_MASKS = {
    "/root/.config/gh": "gh_config_unmask",
    "/root/.config/glab-cli": "WITH_GLAB",
    "/root/.terraform.d": "WITH_TFE",
    "/root/.aws": "WITH_AWS",
    "/root/.aws/cli/cache": "WITH_AWS",
}

# The three single-line masks: applied when the opt-in variable is "0", i.e.
# when the flag is absent. A mask that became unconditional, or got attached to
# the wrong flag, fails to match.
SINGLE_LINE_MASKS = {
    "/root/.config/gh": "gh_config_unmask",
    "/root/.config/glab-cli": "WITH_GLAB",
    "/root/.terraform.d": "WITH_TFE",
}

TMPFS = re.compile(r'MOUNT_ARGS\+=\("--tmpfs" "([^"]+)"\)')
SMOKE_TMPFS = re.compile(r'VOLUME_ARGS\+=\("--tmpfs" "([^"]+)"\)')


def run_sh():
    return RUN_SH.read_text()


class MaskSetTest(unittest.TestCase):
    def test_mask_set_is_exactly_the_reviewed_set(self):
        found = set(TMPFS.findall(run_sh()))
        self.assertEqual(
            found,
            set(EXPECTED_MASKS),
            "run.sh's tmpfs mask set changed. A removed mask lets a prior "
            "session's credential state persist into a session that did not "
            "opt in; an added one needs a spec delta. Update "
            "EXPECTED_MASKS and openspec/specs/external-cli-tools/spec.md "
            "together.",
        )

    def test_single_line_masks_are_gated_on_the_optin_being_off(self):
        text = run_sh()
        for path, guard in SINGLE_LINE_MASKS.items():
            pattern = re.compile(
                r'\[ "\$' + re.escape(guard) + r'" = "0" \]\s*&&\s*'
                r'MOUNT_ARGS\+=\("--tmpfs" "' + re.escape(path) + r'"\)'
            )
            self.assertRegex(
                text,
                pattern,
                f"{path} is no longer masked by [ ${guard} = 0 ]. Either the "
                f"mask became unconditional or it is gated on the wrong flag.",
            )

    def test_gh_mask_keeps_its_three_state_logic(self):
        """gh is the one mask with three states, not two.

        It must stay ON while the auth proxy sidecar is active: the sidecar
        hands the container a placeholder token, so persisted login state is
        unnecessary, and leaving it readable would reintroduce a persisted
        in-container secret. Collapsing this to `[ $WITH_GH = 0 ]` would unmask
        it for every --gh run.
        """
        text = run_sh()
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

    def test_aws_is_masked_in_both_directions_with_a_narrower_scope_under_aws(self):
        """AWS is the only two-scope mask, and both halves are load-bearing.

        Without --aws the whole directory is masked, which is what keeps an
        --aws session's cached STS out of a no-flag session. With --aws the mask
        narrows to the credential cache so the :ro host mounts at
        /root/.aws/config and /root/.aws/sso stay visible — a mask over the
        whole directory there would hide the credentials the flag just granted.
        """
        collapsed = re.sub(r"\s+", " ", run_sh())
        expected = (
            'if [ "$WITH_AWS" = "0" ]; then '
            'MOUNT_ARGS+=("--tmpfs" "/root/.aws") '
            "else "
            'MOUNT_ARGS+=("--tmpfs" "/root/.aws/cli/cache") '
            "fi"
        )
        # assertIn would embed the whole collapsed script in the failure
        # message, burying the one line that matters under 40KB of run.sh.
        self.assertTrue(
            expected in collapsed,
            "the AWS mask pair changed shape or is missing. Expected, "
            f"ignoring whitespace:\n\n    {expected}\n\n"
            "Both branches matter: the if-branch enforces the opt-in boundary, "
            "the else-branch stops an --aws session leaving derived "
            "credentials on the shared volume while keeping the granted :ro "
            "mounts visible.",
        )

    def test_every_mask_sits_inside_the_non_ephemeral_block(self):
        """A mask outside the block is either dead or misleading.

        The masks only mean anything when the named volumes are mounted;
        --ephemeral mounts none, so it needs no masking. A mask that drifted out
        of the block would still be appended to MOUNT_ARGS, but the array is
        rebuilt at the end of the block, so placement is not cosmetic.
        """
        lines = run_sh().splitlines()
        starts = [
            i for i, line in enumerate(lines)
            if re.match(r'\s*if \[ "\$EPHEMERAL" = "0" \]; then', line)
        ]
        self.assertEqual(
            len(starts), 1,
            "expected exactly one EPHEMERAL=0 block guarding the volume mounts",
        )
        start = starts[0]

        ends = [
            i for i, line in enumerate(lines)
            if "MOUNT_ARGS=(-v claude-code-root:/root" in line
        ]
        self.assertEqual(
            len(ends), 1,
            "expected exactly one line prepending the named volumes",
        )
        end = ends[0]
        self.assertGreater(end, start)

        for i, line in enumerate(lines):
            if TMPFS.search(line):
                self.assertTrue(
                    start < i < end,
                    f"tmpfs mask on line {i + 1} sits outside the "
                    f"EPHEMERAL=0 block (lines {start + 1}-{end + 1}): "
                    f"{line.strip()}",
                )


class SmokeMirrorTest(unittest.TestCase):
    """The smoke harness mirrors the mask list instead of calling run.sh.

    That is a deliberate trade-off — it lets the harness exercise credential
    combinations without the host-side discovery run.sh does — but it means the
    mirror can silently fall behind, and a mask present only in run.sh is never
    exercised in a container. Tie the two together here.
    """

    def test_mirror_covers_every_mask_run_sh_applies(self):
        run_masks = set(TMPFS.findall(run_sh()))
        smoke_masks = set(SMOKE_TMPFS.findall(SMOKE_SH.read_text()))
        missing = run_masks - smoke_masks
        self.assertEqual(
            missing,
            set(),
            "smoke/smoke.sh no longer mirrors every mask in run.sh: "
            f"{sorted(missing)} would go unexercised in the container "
            "assertions. Add them to the mirror in smoke.sh.",
        )


if __name__ == "__main__":
    unittest.main()
