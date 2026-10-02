# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Run run.sh under a simulated Git Bash and pin the argv it hands the engine.

There is no Windows CI (GitHub's windows-latest runners can't run Linux
containers), so the Windows-only branches of run.sh — MSYS path translation,
the fixed HOST_UID, safe.directory, the core.autocrlf overlay entry and the
%APPDATA% credential lookups — are exercised here instead, on Linux, by
putting stubs ahead of the real tools on PATH:

  uname    reports MINGW64 (or Linux, for the off-MSYS control case)
  cygpath  -m maps a POSIX path P to "W:P"; -u maps it back
  id       reports Git Bash's synthetic SID-derived IDs
  git      answers core.autocrlf lookups, records the -C path it was given
  docker   records every invocation's argv; `run --rm` also snapshots the
           .git/config overlay, since run.sh's EXIT trap deletes the stage dir

"W:" is a deliberately fake drive so a host path that skipped hostpath() is
unmistakable in the recorded argv.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RUN_SH = ROOT / "run.sh"

STUBS = {
    "uname": """\
        #!/bin/sh
        echo "$FAKE_UNAME"
        """,
    "cygpath": """\
        #!/bin/sh
        case "$1" in
          -m) printf 'W:%s\\n' "$2" ;;
          -u) printf '%s\\n' "$2" | sed -e 's|^W:||' -e 's|\\\\|/|g' ;;
          *)  exit 1 ;;
        esac
        """,
    "id": """\
        #!/bin/sh
        case "$1" in -u) echo 197609 ;; -g) echo 197121 ;; esac
        """,
    "git": """\
        #!/bin/sh
        if [ "$1" = "-C" ] && [ "$4" = "--get" ] && [ "$5" = "core.autocrlf" ]; then
          printf '%s\\n' "$2" >>"$RECORD/git-C"
          echo true
          exit 0
        fi
        exit 1
        """,
    "docker": """\
        #!/bin/bash
        n=$(ls "$RECORD" | grep -c '^call\\.' || true)
        printf '%s\\0' "$@" >"$RECORD/call.$n"
        unwin() { printf '%s' "${1#W:}"; }
        case "$1" in
          ps)      [ "$2" = "-q" ] && echo running ;;
          inspect) echo 10.0.0.2 ;;
          cp)      dest=$(unwin "$3"); [ -d "$(dirname "$dest")" ] && echo CA >"$dest" ;;
          run)
            prev=""
            for a in "$@"; do
              if [ "$prev" = "-v" ]; then
                case "$a" in
                  *:/workspaces/*/.git/config) src="${a%:/workspaces/*}"; cp "$(unwin "$src")" "$RECORD/overlay" ;;
                esac
              fi
              prev="$a"
            done ;;
        esac
        exit 0
        """,
}


class Harness:
    def __init__(self, uname):
        self.tmp = tempfile.TemporaryDirectory()
        base = Path(self.tmp.name)
        self.bin = base / "bin"
        self.record = base / "record"
        self.home = base / "home"
        self.appdata = self.home / "AppData" / "Roaming"
        self.ws = base / "ws" / "repo"
        for d in (self.bin, self.record, self.home, self.ws / ".git"):
            d.mkdir(parents=True)
        (self.ws / ".git" / "config").write_text("[core]\n\tbare = false\n")
        for name, body in STUBS.items():
            p = self.bin / name
            p.write_text(textwrap.dedent(body))
            p.chmod(0o755)
        self.env = {
            "PATH": f"{self.bin}:/usr/bin:/bin",
            "HOME": str(self.home),
            "FAKE_UNAME": uname,
            "RECORD": str(self.record),
            "CLAUDE_DOCKER_RUNTIME": "docker",
            # Windows form, as Git Bash inherits it from the Windows environment.
            "APPDATA": "W:" + str(self.appdata).replace("/", "\\"),
        }

    def run(self, *args, **env):
        return subprocess.run(
            ["bash", str(RUN_SH), *args, str(self.ws)],
            env={**self.env, **env},
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=60,
        )

    def calls(self):
        out = []
        for p in sorted(self.record.glob("call.*"), key=lambda p: int(p.suffix[1:])):
            out.append(p.read_bytes().decode().split("\0")[:-1])
        return out

    def agent_run(self):
        runs = [c for c in self.calls() if c[:2] == ["run", "--rm"]]
        assert len(runs) == 1, runs
        return runs[0]

    def cleanup(self):
        self.tmp.cleanup()


def pairs(argv, flag):
    return [argv[i + 1] for i, a in enumerate(argv[:-1]) if a == flag]


class GitBashTest(unittest.TestCase):
    def setUp(self):
        self.h = Harness("MINGW64_NT-10.0-26100")

    def tearDown(self):
        self.h.cleanup()

    def start(self, *args, **env):
        r = self.h.run(*args, **env)
        self.assertEqual(r.returncode, 0, r.stderr)
        return self.h.agent_run()

    def test_container_paths_verbatim_and_host_paths_windows_form(self):
        argv = self.start()
        self.assertIn(f"W:{self.h.ws}:/workspaces/repo", pairs(argv, "-v"))
        self.assertEqual(pairs(argv, "-w"), ["/workspaces/repo"])

    def test_fixed_non_root_uid(self):
        env = pairs(self.start(), "-e")
        self.assertIn("HOST_UID=1000", env)
        self.assertIn("HOST_GID=1000", env)

    def test_safe_directory_scoped_to_workspaces(self):
        env = pairs(self.start(), "-e")
        self.assertIn("GIT_CONFIG_COUNT=1", env)
        self.assertIn("GIT_CONFIG_KEY_0=safe.directory", env)
        self.assertIn("GIT_CONFIG_VALUE_0=/workspaces/*", env)

    def test_overlay_carries_host_autocrlf(self):
        self.start()
        self.assertIn("autocrlf = true", (self.h.record / "overlay").read_text())
        # git.exe is native: the -C path must be Windows-form too.
        self.assertEqual((self.h.record / "git-C").read_text().strip(), f"W:{self.h.ws}")

    def test_gh_proxy_cp_destination_is_windows_form(self):
        self.start("--gh", GH_TOKEN="ghp_fake")
        cps = [c for c in self.h.calls() if c[0] == "cp"]
        self.assertTrue(cps, "run.sh never extracted the sidecar CA")
        self.assertTrue(cps[0][2].startswith("W:"), cps[0])
        self.assertTrue(cps[0][2].endswith("/gh-proxy/root.crt"), cps[0])

    def test_appdata_credential_lookups(self):
        a = self.h.appdata
        files = {
            a / "terraform.d" / "credentials.tfrc.json": "/root/.terraform.d/credentials.tfrc.json:ro",
            a / "uv" / "uv.toml": "/root/.config/uv/uv.toml:ro",
            a / "pip" / "pip.ini": "/root/.config/pip/pip.conf:ro",
            a / "glab-cli": "/root/.config/glab-cli:ro",
        }
        for path in files:
            if path.name == "glab-cli":
                path.mkdir(parents=True)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("x")
        mounts = pairs(self.start("--tfe", "--registry", "--glab"), "-v")
        for path, target in files.items():
            self.assertIn(f"W:{path}:{target}", mounts)

    def test_appdata_lookups_stay_behind_their_optin(self):
        (self.h.appdata / "terraform.d").mkdir(parents=True)
        (self.h.appdata / "terraform.d" / "credentials.tfrc.json").write_text("x")
        mounts = pairs(self.start(), "-v")
        self.assertFalse([m for m in mounts if "terraform.d" in m and not m.startswith("claude-code")])


class OffMsysTest(unittest.TestCase):
    """Control case: none of the Windows handling may leak onto Linux/macOS."""

    def setUp(self):
        self.h = Harness("Linux")

    def tearDown(self):
        self.h.cleanup()

    def test_argv_has_no_windows_handling(self):
        (self.h.appdata / "terraform.d").mkdir(parents=True)
        (self.h.appdata / "terraform.d" / "credentials.tfrc.json").write_text("x")
        r = self.h.run("--tfe")
        self.assertEqual(r.returncode, 0, r.stderr)
        argv = self.h.agent_run()
        env = pairs(argv, "-e")
        mounts = pairs(argv, "-v")
        self.assertIn("HOST_UID=197609", env)
        self.assertIn("HOST_GID=197121", env)
        self.assertFalse([e for e in env if e.startswith("GIT_CONFIG_")])
        self.assertIn(f"{self.h.ws}:/workspaces/repo", mounts)
        self.assertFalse([m for m in mounts if "terraform.d" in m])
        self.assertNotIn("autocrlf", (self.h.record / "overlay").read_text())


class PowerShellLauncherTest(unittest.TestCase):
    """claude-docker.ps1 can't run in CI (no pwsh), so pin its invariants statically."""

    def setUp(self):
        self.text = (ROOT / "claude-docker.ps1").read_text()
        # Code only — the comments legitimately mention System32\bash.exe.
        self.code = "\n".join(
            line for line in self.text.splitlines() if not line.lstrip().startswith("#")
        )

    def test_never_invokes_a_bare_bash(self):
        """A bare `bash` in PowerShell is usually WSL's System32\\bash.exe."""
        self.assertNotRegex(self.code, r"(?im)^\s*&?\s*bash(\.exe)?\b")
        self.assertNotRegex(self.code, r"(?i)Get-Command\s+bash")
        self.assertIn("'bin\\bash.exe'", self.code)
        self.assertTrue(re.search(r"Get-Command git\.exe", self.code))

    def test_hands_all_arguments_to_run_sh_and_propagates_exit_code(self):
        self.assertIn("& $bash $runSh @args", self.code)
        self.assertIn("exit $code", self.code)


class GitattributesTest(unittest.TestCase):
    def test_scripts_and_pins_check_out_lf(self):
        files = ["run.sh", "entrypoint.sh", "Dockerfile", "claude-docker.ps1"] + [
            str(p.relative_to(ROOT)) for p in (ROOT / "pins").glob("*.env")
        ]
        out = subprocess.run(
            ["git", "check-attr", "eol", "--", *files],
            cwd=ROOT, capture_output=True, text=True, check=True,
        ).stdout
        for line in out.splitlines():
            self.assertTrue(line.endswith(": eol: lf"), line)
        self.assertEqual(len(out.splitlines()), len(files))


if __name__ == "__main__":
    unittest.main()
