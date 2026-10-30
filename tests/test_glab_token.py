# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""Drive run.sh with stub `docker` and `glab` to pin --glab token discovery.

With GITLAB_TOKEN unset, --glab / --glab-direct ask host glab for a token
(GITLAB_HOST, else the workspace's origin host -- resolved through worktrees --
then glab's default host). An explicit GITLAB_TOKEN wins; finding none, or no
glab on PATH, warns. Discovery is shared, so it is pinned once, under
--glab-direct, where the token is forwarded by bare name, never on argv.
Under --glab the token goes to the auth-proxy sidecar instead and the agent
container gets a placeholder (GlabProxied below).

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"
SECRET = "glpat-from-host-glab"

# Records the agent `run --rm`: argv plus the values docker would read for
# GITLAB_TOKEN / GITLAB_HOST. The sidecar `run -d` is recorded separately, and
# the subcommands start_auth_sidecar polls answer as a healthy sidecar would.
# Everything else (stale-sidecar sweep, network) is a silent no-op.
DOCKER = """#!/bin/sh
case "$1" in
  logs) echo '{"msg":"serving initial configuration"}'; exit 0 ;;
  cp) echo CA > "$3"; exit 0 ;;
  ps) [ "$2" = "-q" ] && echo cid; exit 0 ;;
  inspect) echo 10.0.0.2; exit 0 ;;
  run) ;;
  *) exit 0 ;;
esac
if [ "$2" = "-d" ]; then
  printf '%s\\n' "$@" > "$STUB_LOG/sidecar-argv"
  printf '%s' "${GLAB_PROXY_BEARER:-}" > "$STUB_LOG/sidecar-bearer"
  printf '%s' "${GLAB_PROXY_SITE:-}" > "$STUB_LOG/sidecar-site"
  for a; do case "$a" in *:/etc/caddy:ro) cp -R "${a%%:*}" "$STUB_LOG/caddy" ;; esac; done
  exit 0
fi
printf '%s\\n' "$@" > "$STUB_LOG/argv"
printf '%s' "${GITLAB_TOKEN:-}" > "$STUB_LOG/token"
printf '%s' "${GITLAB_HOST:-}" > "$STUB_LOG/host"
for a; do case "$a" in *:/root/.config/glab-cli/config.yml:ro) cp -p "${a%%:*}" "$STUB_LOG/glab-config.yml" ;; esac; done
"""
# Host glab: answers `config get host` from GITLAB_HOST (as real glab does) and
# holds tokens for gl.example.com and other.example.com, returned solely via
# `config get token --host` -- the call real glab answers from the OS keyring
# under use_keyring.
GLAB = f"""#!/bin/sh
[ "$*" = "config get host" ] && {{ echo "$GITLAB_HOST"; exit 0; }}
[ "$*" = "config get token --host gl.example.com" ] && echo "{SECRET}"
[ "$*" = "config get token --host other.example.com" ] && echo "glpat-other-host"
[ "$*" = "config get token --host port.example.com:8443" ] && echo "glpat-port-host"
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

    def _run(self, drop=(), path="/usr/bin:/bin", flag="--glab-direct", **extra):
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
            ["bash", str(RUN_SH), flag, str(self.ws)],
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

    def test_config_overlay_turns_keyring_off(self):
        # In-container glab reads job_token via the keyring under use_keyring,
        # even with GITLAB_TOKEN set, and fails without D-Bus.
        self._run()
        cfg = (self.log / "glab-config.yml").read_text()
        self.assertIn("    use_keyring: false\n", cfg)
        self.assertNotIn("use_keyring: true", cfg)
        self.assertIn("api_host: gl.example.com", cfg)

    def test_config_overlay_is_owner_only(self):
        # glab refuses a config.yml that others can read (#168), and the copy
        # is mounted :ro, so the mode can't be fixed inside the container.
        self._run()
        self.assertEqual((self.log / "glab-config.yml").stat().st_mode & 0o777, 0o600)

    def test_no_host_config_skips_overlay(self):
        (self.home / ".config" / "glab-cli" / "config.yml").unlink()
        argv, _ = self._run()
        self.assertFalse(any(a.endswith(":/root/.config/glab-cli/config.yml:ro") for a in argv))

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
        # The token is for gl.example.com, so the in-container glab must target
        # it too, not its gitlab.com default.
        self.assertIn("GITLAB_HOST", argv)
        self.assertEqual((self.log / "host").read_text(), "gl.example.com")

    def test_explicit_gitlab_host_forwarded_unchanged(self):
        argv, _ = self._run()
        self.assertEqual(argv.count("GITLAB_HOST"), 1)
        self.assertEqual((self.log / "host").read_text(), "https://gl.example.com")

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

    # -- host parsing (#131) --

    def test_gitlab_host_keeps_port(self):
        _, token = self._run(GITLAB_HOST="port.example.com:8443")
        self.assertEqual(token, "glpat-port-host")

    def test_https_origin_keeps_port(self):
        self._init_repo(self.ws, "https://port.example.com:8443/group/project.git")
        _, token = self._run(drop=("GITLAB_HOST",))
        self.assertEqual(token, "glpat-port-host")

    def test_ssh_origin_drops_ssh_port(self):
        self._init_repo(self.ws, "ssh://git@gl.example.com:2222/group/project.git")
        _, token = self._run(drop=("GITLAB_HOST",))
        self.assertEqual(token, SECRET)

    def test_at_in_path_and_password_does_not_move_host(self):
        for url in ("https://gl.example.com/group/repo@x.git",
                    "https://user:p@ss@gl.example.com/group/repo.git"):
            with self.subTest(url=url):
                subprocess.run(["rm", "-rf", str(self.ws / ".git")], check=True)
                self._init_repo(self.ws, url)
                _, token = self._run(drop=("GITLAB_HOST",))
                self.assertEqual(token, SECRET)

    def test_duplicate_host_tried_once(self):
        self._init_repo(self.ws, "git@gitlab.com:group/project.git")
        self._run(drop=("GITLAB_HOST",))
        self.assertIn("no GitLab token found for gitlab.com;", self.stderr)

    # -- origin lookup skips (#131): only glab's default host is tried --

    def _assert_only_default_tried(self):
        _, token = self._run(drop=("GITLAB_HOST",))
        self.assertEqual(token, "")
        self.assertIn("no GitLab token found for gitlab.com;", self.stderr)

    def test_symlinked_dot_git_skipped(self):
        other = Path(self.tmp.name) / "other"
        self._init_repo(other, "git@gl.example.com:group/project.git")
        (self.ws / ".git").symlink_to(other / ".git")
        self._assert_only_default_tried()

    def test_symlinked_config_skipped(self):
        other = Path(self.tmp.name) / "other"
        self._init_repo(other, "git@gl.example.com:group/project.git")
        self._init_repo(self.ws, "git@gitlab.com:group/project.git")
        cfg = self.ws / ".git" / "config"
        cfg.unlink()
        cfg.symlink_to(other / ".git" / "config")
        self._assert_only_default_tried()

    def test_unresolvable_git_pointer_skipped(self):
        (self.ws / ".git").write_text("gitdir: /nonexistent/claude-docker-test\n")
        self._assert_only_default_tried()


class GlabProxied(unittest.TestCase):
    """--glab: same discovery, but the token stays in the sidecar."""

    # Same fixtures; not a subclass, so the discovery cases don't run twice.
    setUp = GlabTokenDiscovery.setUp
    tearDown = GlabTokenDiscovery.tearDown
    _run = GlabTokenDiscovery._run

    def _proxied(self, **extra):
        argv, token = self._run(flag="--glab", **extra)
        side = (self.log / "sidecar-argv").read_text().splitlines()
        return argv, token, side

    def test_token_reaches_only_the_sidecar(self):
        argv, token, side = self._proxied()
        self.assertEqual(token, "")  # docker reads no real GITLAB_TOKEN for the agent
        self.assertIn("GITLAB_TOKEN=claude-docker-proxy", argv)
        self.assertNotIn("GITLAB_TOKEN", argv)
        self.assertEqual((self.log / "sidecar-bearer").read_text(), f"Bearer {SECRET}")
        self.assertEqual((self.log / "sidecar-site").read_text(), "gl.example.com")
        self.assertIn("gl.example.com:10.0.0.2", argv)
        self.assertFalse(any(SECRET in a for a in argv + side))
        self.assertNotIn(SECRET, "".join(f.read_text() for f in (self.log / "caddy").rglob("*") if f.is_file()))
        self.assertIn("auth-proxy sidecar", self.stderr)

    def test_explicit_token_reaches_only_the_sidecar(self):
        argv, _, _ = self._proxied(GITLAB_TOKEN="glpat-explicit")
        self.assertEqual((self.log / "sidecar-bearer").read_text(), "Bearer glpat-explicit")
        self.assertIn("GITLAB_TOKEN=claude-docker-proxy", argv)

    def test_port_is_kept_for_site_and_dropped_for_add_host(self):
        argv, _, _ = self._proxied(GITLAB_HOST="port.example.com:8443")
        self.assertEqual((self.log / "sidecar-site").read_text(), "port.example.com:8443")
        self.assertIn("port.example.com:10.0.0.2", argv)

    def test_config_copy_has_no_tokens(self):
        cfg = self.home / ".config" / "glab-cli" / "config.yml"
        cfg.write_text("hosts:\n  gl.example.com:\n    token: glpat-in-file\n    use_keyring: true\n"
                       "  gitlab.com:\n    token: glpat-other-in-file\n")
        self._proxied()
        copy = (self.log / "glab-config.yml").read_text()
        self.assertNotIn("glpat-in-file", copy)
        self.assertNotIn("glpat-other-in-file", copy)
        self.assertIn("    use_keyring: false\n", copy)

    def test_no_token_starts_no_sidecar(self):
        argv, _ = self._run(flag="--glab", drop=("GITLAB_HOST",))
        self.assertFalse((self.log / "sidecar-argv").exists())
        self.assertFalse(any("GITLAB_TOKEN" in a for a in argv))
        self.assertIn("no GitLab token found", self.stderr)


if __name__ == "__main__":
    unittest.main()
