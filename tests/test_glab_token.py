# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Drive run.sh with stub `docker` and `glab` to pin --glab token discovery.

With GITLAB_TOKEN unset, --glab asks host glab for a token (GITLAB_HOST, else
the workspace's origin host -- resolved through worktrees -- then glab's default
host) and forwards it by bare name, never on argv. An explicit GITLAB_TOKEN
wins; finding none, or no glab on PATH, warns.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"
SECRET = "glpat-from-host-glab"

# Records `run` invocations: argv plus the value docker would read for
# GITLAB_TOKEN. Every other subcommand (stale-sidecar sweep) is a silent no-op.
DOCKER = """#!/bin/sh
[ "$1" = run ] || exit 0
printf '%s\\n' "$@" > "$STUB_LOG/argv"
printf '%s' "${GITLAB_TOKEN:-}" > "$STUB_LOG/token"
"""
# Host glab: answers `config get host` from GITLAB_HOST (as real glab does) and
# holds tokens for gl.example.com and other.example.com, returned solely via
# `config get token --host` -- the call real glab answers from the OS keyring
# under use_keyring.
GLAB = f"""#!/bin/sh
[ "$*" = "config get host" ] && {{ echo "$GITLAB_HOST"; exit 0; }}
[ "$*" = "config get token --host gl.example.com" ] && echo "{SECRET}"
[ "$*" = "config get token --host other.example.com" ] && echo "glpat-other-host"
exit 0
"""


class GlabTokenDiscovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = Path(self.tmp.name)
        self.bin, self.log, self.home, self.ws = (t / d for d in ("bin", "log", "home", "ws"))
        for d in (self.bin, self.log, self.home, self.ws):
            d.mkdir()
        for name, body in (("docker", DOCKER), ("glab", GLAB)):
            p = self.bin / name
            p.write_text(body)
            p.chmod(0o755)
        # Keyring-backed login: config.yml carries no token for the host.
        cfg = self.home / ".config" / "glab-cli"
        cfg.mkdir(parents=True)
        (cfg / "config.yml").write_text(
            "hosts:\n  gl.example.com:\n    use_keyring: true\n    api_host: gl.example.com\n")

    def tearDown(self):
        self.tmp.cleanup()

    @staticmethod
    def _init_repo(path, origin):
        subprocess.run(["git", "init", "-q", str(path)], check=True)
        subprocess.run(["git", "-C", str(path), "remote", "add", "origin", origin], check=True)

    def _run(self, drop=(), path="/usr/bin:/bin", **extra):
        env = {
            "PATH": f"{self.bin}:{path}",
            "HOME": str(self.home),
            "STUB_LOG": str(self.log),
            "CLAUDE_DOCKER_RUNTIME": "docker",
            "GITLAB_HOST": "https://gl.example.com",
            **extra,
        }
        for k in drop:
            env.pop(k)
        r = subprocess.run(
            ["bash", str(RUN_SH), "--glab", str(self.ws)],
            env=env, capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        self.stderr = r.stderr
        return (self.log / "argv").read_text().splitlines(), (self.log / "token").read_text()

    def test_keyring_token_discovered_and_forwarded_by_name(self):
        argv, token = self._run()
        self.assertEqual(token, SECRET)
        self.assertIn("GITLAB_TOKEN", argv)
        self.assertIn("GITLAB_HOST", argv)
        self.assertFalse(any(SECRET in a for a in argv))

    def test_explicit_token_wins(self):
        _, token = self._run(GITLAB_TOKEN="glpat-explicit")
        self.assertEqual(token, "glpat-explicit")

    def test_origin_remote_host_discovered_without_gitlab_host(self):
        # glab's default host is gitlab.com (no token); origin points at the
        # instance that holds one (#126).
        self._init_repo(self.ws, "git@gl.example.com:group/project.git")
        argv, token = self._run(drop=("GITLAB_HOST",))
        self.assertEqual(token, SECRET)
        self.assertFalse(any(SECRET in a for a in argv))
        self.assertNotIn("no GitLab token", self.stderr)

    def test_gitlab_host_beats_origin(self):
        # origin's host also has a token; it must not be the one forwarded.
        self._init_repo(self.ws, "git@other.example.com:group/project.git")
        _, token = self._run()
        self.assertEqual(token, SECRET)

    def test_worktree_workspace_uses_main_repo_origin(self):
        # In a worktree .git is a pointer file; the remote lives in the main repo.
        main = Path(self.tmp.name) / "main"
        self._init_repo(main, "git@gl.example.com:group/project.git")
        git = ["git", "-c", "user.name=t", "-c", "user.email=t@t", "-C", str(main)]
        subprocess.run(git + ["commit", "-q", "--allow-empty", "-m", "init"], check=True)
        self.ws.rmdir()
        subprocess.run(git + ["worktree", "add", "-q", "--detach", str(self.ws)], check=True)
        _, token = self._run(drop=("GITLAB_HOST",))
        self.assertEqual(token, SECRET)

    def test_no_glab_on_path_warns(self):
        # Host PATH minus any real glab; with no GITLAB_HOST and no origin the
        # candidate list is empty, which must not trip bash 3.2's set -u.
        (self.bin / "glab").unlink()
        sysbin = Path(self.tmp.name) / "sysbin"
        sysbin.mkdir()
        for d in ("/usr/bin", "/bin"):
            for name in os.listdir(d):
                if name != "glab" and not (sysbin / name).exists():
                    (sysbin / name).symlink_to(Path(d) / name)
        argv, token = self._run(drop=("GITLAB_HOST",), path=str(sysbin))
        self.assertEqual(token, "")
        self.assertNotIn("GITLAB_TOKEN", argv)
        self.assertIn("glab not on host PATH", self.stderr)

    def test_no_token_warns_with_hosts_tried(self):
        argv, token = self._run(drop=("GITLAB_HOST",))
        self.assertEqual(token, "")
        self.assertNotIn("GITLAB_TOKEN", argv)
        self.assertIn("no GitLab token found for gitlab.com", self.stderr)


if __name__ == "__main__":
    unittest.main()
