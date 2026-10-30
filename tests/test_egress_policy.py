# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
"""--api --egress-lock locks model traffic to ANTHROPIC_BASE_URL.

The endpoint checks run before container-runtime detection, so these cases
need no docker: an endpoint that passes stops at the invalid
CLAUDE_DOCKER_RUNTIME the helper sets.

Stdlib only, so CI's unit-test step keeps running with no install step.
"""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

RUN_SH = Path(__file__).resolve().parent.parent / "run.sh"


def run(args, **env_extra):
    env = {k: v for k, v in os.environ.items()
           if not k.startswith(("ANTHROPIC_", "CLAUDE_DOCKER_"))}
    env.update(ANTHROPIC_AUTH_TOKEN="sk-test", CLAUDE_DOCKER_RUNTIME="none", **env_extra)
    with tempfile.TemporaryDirectory() as ws:
        return subprocess.run(["bash", str(RUN_SH), *args, ws],
                              env=env, capture_output=True, text=True, timeout=30)


class Endpoint(unittest.TestCase):
    def assert_refused(self, needle, args=("--api", "--egress-lock"), **env):
        r = run(list(args), **env)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertIn(needle, r.stderr)

    def test_needs_api(self):
        self.assert_refused("--egress-lock needs --api", args=["--egress-lock"],
                            ANTHROPIC_BASE_URL="https://llm.example.eu")

    def test_base_url_required(self):
        self.assert_refused("--egress-lock needs ANTHROPIC_BASE_URL")

    def test_api_alone_skips_the_lock(self):
        # No ANTHROPIC_BASE_URL: the lock would refuse this, --api alone doesn't.
        r = run(["--api"])
        self.assertIn("CLAUDE_DOCKER_RUNTIME must be", r.stderr)

    def test_provider_endpoint_refused(self):
        for url in ("https://api.anthropic.com", "https://x.claude.ai/v1", "https://claude.com",
                    # Hostnames are case-insensitive, and so is squid's dstdomain.
                    "https://Api.Anthropic.com", "https://X.CLAUDE.AI/v1"):
            with self.subTest(url=url):
                self.assert_refused("points at one", ANTHROPIC_BASE_URL=url)

    def test_injection_refused(self):
        self.assert_refused("is not a valid hostname",
                            ANTHROPIC_BASE_URL="https://a.eu\nhttp_access allow all/")
        self.assert_refused("is not a valid hostname", ANTHROPIC_BASE_URL="https://a b.eu/")

    def test_invalid_port_refused(self):
        # The port is written into squid.conf, so it is validated like the host.
        for url in ("https://gw.example.eu:0", "https://gw.example.eu:65536",
                    "https://gw.example.eu:80a/v1", "https://gw.example.eu:123456"):
            with self.subTest(url=url):
                self.assert_refused("is not a port number", ANTHROPIC_BASE_URL=url)

    def test_gateway_passes(self):
        for url in ("https://llm.example.eu/v1", "https://u:p@10.1.2.3:8443", "https://notanthropic.com",
                    "http://litellm:4000", "https://gw.example.eu:443/v1"):
            with self.subTest(url=url):
                r = run(["--api", "--egress-lock"], ANTHROPIC_BASE_URL=url)
                self.assertIn("CLAUDE_DOCKER_RUNTIME must be", r.stderr)


SENTINEL = "CLAUDE_DOCKER_RUNTIME must be"
GW = {"ANTHROPIC_BASE_URL": "https://gw.example.eu"}


class Allowlist(unittest.TestCase):
    """--egress-allowlist checks, all before runtime detection.

    Each case runs in a temp HOME with explicit workspaces, so containment
    is tested against real paths. Rejected cases must stop before the
    runtime sentinel and leave nothing under HOME's state dir.
    """

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.home = Path(self.tmp.name)
        self.repo = self.home / "repo"
        self.repo.mkdir()

    def tearDown(self):
        self.tmp.cleanup()

    def write(self, name, data):
        f = self.home / name
        f.parent.mkdir(parents=True, exist_ok=True)
        f.write_bytes(data if isinstance(data, bytes) else data.encode())
        return f

    def run_sh(self, args, workspaces=None, **env_extra):
        env = {k: v for k, v in os.environ.items()
               if not k.startswith(("ANTHROPIC_", "CLAUDE_DOCKER_", "XDG_", "GH_", "GITHUB_", "GITLAB_"))}
        env.update(HOME=str(self.home), ANTHROPIC_AUTH_TOKEN="sk-test",
                   CLAUDE_DOCKER_RUNTIME="none", **GW)
        env.update(env_extra)
        ws = [str(w) for w in (workspaces or [self.repo])]
        return subprocess.run(["bash", str(RUN_SH), "--api", "--egress-lock", *args, *ws],
                              env=env, capture_output=True, text=True, timeout=30, cwd=self.home)

    def state_files(self):
        state = self.home / ".local" / "state"
        return list(state.rglob("*")) if state.exists() else []

    def accepted(self, args, **kw):
        r = self.run_sh(args, **kw)
        self.assertIn(SENTINEL, r.stderr)
        self.assertNotIn("egress-allowlist", r.stderr)
        return r

    def refused(self, args, *needles, **kw):
        r = self.run_sh(args, **kw)
        self.assertEqual(r.returncode, 1, r.stderr)
        self.assertNotIn(SENTINEL, r.stderr)
        for n in needles:
            self.assertIn(n, r.stderr)
        self.assertEqual(self.state_files(), [])
        return r

    def entries(self, text):
        f = self.write("team.allow", text)
        return [f"--egress-allowlist={f}"]

    # --- prerequisites and file selection ---

    def test_needs_the_lock(self):
        f = self.write("team.allow", "")
        r = subprocess.run(["bash", str(RUN_SH), "--api", f"--egress-allowlist={f}", str(self.repo)],
                           env={**{k: v for k, v in os.environ.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_DOCKER_"))},
                                "HOME": str(self.home), "ANTHROPIC_AUTH_TOKEN": "t", "CLAUDE_DOCKER_RUNTIME": "none", **GW},
                           capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 1)
        self.assertIn("--egress-allowlist needs --egress-lock", r.stderr)

    def test_no_file_named(self):
        self.refused(["--egress-allowlist"], "--egress-allowlist needs a file")

    def test_no_fixed_fallback_file(self):
        xdg = self.write(".config/claude-docker/egress-allowlist", "fallback-secret.example\n")
        r = self.refused(["--egress-allowlist"], "--egress-allowlist needs a file",
                         XDG_CONFIG_HOME=str(xdg.parent.parent))
        self.assertNotIn("fallback-secret", r.stderr + r.stdout)

    def test_space_form_hint(self):
        f = self.write("team.allow", "")
        self.refused(["--egress-allowlist", str(f)], "--egress-allowlist=FILE")

    def test_env_var_names_the_file(self):
        f = self.write("team.allow", "pypi.org\n")
        self.accepted(["--egress-allowlist"], CLAUDE_DOCKER_EGRESS_ALLOWLIST=str(f))

    def test_tilde_expanded(self):
        self.write("team.allow", "pypi.org\n")
        self.accepted(["--egress-allowlist=~/team.allow"])
        self.accepted(["--egress-allowlist"], CLAUDE_DOCKER_EGRESS_ALLOWLIST="~/team.allow")

    def test_env_var_ignored_without_the_flag(self):
        r = self.run_sh([], CLAUDE_DOCKER_EGRESS_ALLOWLIST="/nonexistent")
        self.assertIn(SENTINEL, r.stderr)
        self.assertNotIn("allowlist", r.stderr)

    # --- the file ---

    def test_missing_file(self):
        self.refused(["--egress-allowlist=/nonexistent"], "not a readable regular file", "/nonexistent")

    def test_directory(self):
        self.refused([f"--egress-allowlist={self.home}"], "not a readable regular file")

    def test_control_bytes(self):
        for data in (b"pypi.org\n\x00\n", b"pypi.org\x1f\n", b"pypi.org\x1b[31m\n"):
            with self.subTest(data=data):
                f = self.write("team.allow", data)
                self.refused([f"--egress-allowlist={f}"], "control bytes", str(f.name))

    def test_symlink_chain_limit(self):
        target = self.write("team.allow", "pypi.org\n")
        prev = target
        for i in range(41):
            link = self.home / f"l{i}"
            link.symlink_to(prev.name)
            prev = link
        self.accepted([f"--egress-allowlist={self.home / 'l39'}"])  # 40 links
        self.refused([f"--egress-allowlist={self.home / 'l40'}"], "longer than 40 links", "--egress-allowlist")

    def test_symlink_loop(self):
        (self.home / "a").symlink_to("b")
        (self.home / "b").symlink_to("a")
        self.refused([f"--egress-allowlist={self.home / 'a'}"], "longer than 40 links")

    # --- containment ---

    def test_inside_the_workspace(self):
        f = self.write("repo/allow", "pypi.org\n")
        for path in (str(f), f"{self.home}/repo2/../repo/allow", "repo/allow", "./repo//allow"):
            with self.subTest(path=path):
                (self.home / "repo2").mkdir(exist_ok=True)
                self.refused([f"--egress-allowlist={path}"], "lies inside the workspace")

    def test_symlinked_workspace(self):
        real = self.home / "data" / "work"
        real.mkdir(parents=True)
        (self.home / "work").symlink_to(real)
        f = self.write("data/work/allow", "pypi.org\n")
        self.refused([f"--egress-allowlist={f}"], "lies inside the workspace",
                     workspaces=[self.home / "work"])
        self.refused([f"--egress-allowlist={f}"], "lies inside the workspace",
                     workspaces=[f"{self.home}/work/"])

    def test_symlinks_into_the_workspace(self):
        self.write("repo/allow", "pypi.org\n")
        (self.home / "abs.allow").symlink_to(self.repo / "allow")
        (self.home / "rel.allow").symlink_to("repo/allow")
        (self.home / "chain.allow").symlink_to("rel.allow")
        (self.home / "dirlink").symlink_to(self.repo)
        for name in ("abs.allow", "rel.allow", "chain.allow", "dirlink/allow"):
            with self.subTest(name=name):
                self.refused([f"--egress-allowlist={self.home / name}"], "lies inside the workspace")

    def test_trailing_slash_on_a_symlink(self):
        # `[ -L link/ ]` is false, but `cat link/` can still follow the link.
        self.write("repo/allow", "pypi.org\n")
        (self.home / "team.allow").symlink_to(self.repo / "allow")
        (self.home / "slash.allow").symlink_to(str(self.repo / "allow") + "/")
        for path in (f"{self.home}/team.allow/", f"{self.home}/slash.allow"):
            with self.subTest(path=path):
                self.refused([f"--egress-allowlist={path}"])
                self.refused(["--egress-allowlist"], CLAUDE_DOCKER_EGRESS_ALLOWLIST=path)

    def test_dotdot_after_a_symlinked_workspace(self):
        # `cd ~/work && claude-docker ..` mounts $HOME (logical ..), not /data.
        real = self.home / "data" / "work"
        real.mkdir(parents=True)
        (self.home / "work").symlink_to(real)
        f = self.write("team.allow", "pypi.org\n")
        self.refused([f"--egress-allowlist={f}"], "lies inside the workspace",
                     workspaces=[f"{self.home}/work/.."])

    def test_read_only_second_workspace(self):
        docs = self.home / "docs"
        docs.mkdir()
        f = self.write("docs/allow", "pypi.org\n")
        self.refused(["--ro", f"--egress-allowlist={f}"], "lies inside the workspace", str(docs),
                     workspaces=[self.repo, docs])

    def test_sibling_directory(self):
        f = self.write("repo2/allow", "pypi.org\n")
        self.accepted([f"--egress-allowlist={f}"])

    def test_policy_snippet_inside_a_workspace(self):
        f = self.write("team.allow", ".github.com\n")
        policy = self.write("repo/gh.caddy", "")
        self.refused(["--gh", f"--egress-allowlist={f}"], "CLAUDE_DOCKER_GH_POLICY", "lies inside the workspace",
                     CLAUDE_DOCKER_GH_POLICY=str(policy))
        glab = self.write("repo/glab.caddy", "")
        self.refused(["--glab", f"--egress-allowlist={f}"], "CLAUDE_DOCKER_GLAB_POLICY",
                     CLAUDE_DOCKER_GLAB_POLICY=str(glab))
        outside = self.write("gh.caddy", "")
        self.accepted(["--gh", f"--egress-allowlist={f}"], CLAUDE_DOCKER_GH_POLICY=str(outside))

    def test_upstream_overrides_refused(self):
        f = self.write("team.allow", ".github.com\n")
        for var in ("CLAUDE_DOCKER_GH_UPSTREAM", "CLAUDE_DOCKER_GLAB_UPSTREAM"):
            with self.subTest(var=var):
                self.refused(["--gh", f"--egress-allowlist={f}"], var, **{var: "https://other.example"})

    # --- entries ---

    def test_every_entry_form_accepted(self):
        self.accepted(self.entries(
            "# team list\nPyPI.org  # index\n.corp.example\ngit.example.com:8443\n.internal.example:8443\n"
            "pypi.org#index\nexample.org\t#c\n\n   \nnotanthropic.com\nanthropic.com.corp.example\n"
            "a.example:1\nb.example:65535\nlast.example"))

    def test_crlf_and_boundary_values(self):
        long_host = ".".join(["a" * 63, "b" * 63, "c" * 63, "d" * 61])
        self.assertEqual(len(long_host), 253)
        self.accepted(self.entries(f"{long_host}\r\npypi.org\r\nlast.example"))

    def test_invalid_entries(self):
        for line in ("-a.example.com", "a-.example.com", "a..example.com", "a_b.example.com",
                     "example.com.", ".".join(["a" * 63] * 4), "a" * 64 + ".example.com", ".com",
                     "example.com:", "example.com:0", "example.com:65536", "example.com:http",
                     "https://example.com", "example.com/x", "example.com all", "example.com\tall",
                     "example.com\rx", "*.example.com", "example.com;x", "'x.example'"):
            with self.subTest(line=line):
                self.refused(self.entries(f"# head\n{line}\n"), "team.allow:2")

    def test_wildcard_hint(self):
        self.refused(self.entries("a.example\nb.example\n*.example.com\n"), "team.allow:3", "'.example.com'")

    def test_every_invalid_line_named(self):
        r = self.refused(self.entries("ok.example\nbad_one\nok2.example\n\n.com\n"), "team.allow:2", "team.allow:5")
        self.assertNotIn("team.allow:3", r.stderr)

    def test_addresses_refused(self):
        for line in ("10.0.0.5", "167772165", "10.5", "0x7f000001", "0X7F000001", "10.0.0.5:8443"):
            with self.subTest(line=line):
                self.refused(self.entries(line + "\n"), "IP entries are not supported")

    def test_provider_hosts_refused(self):
        for line in ("api.anthropic.com", "API.Anthropic.com", ".ANTHROPIC.com", ".anthropic.com:8443",
                     "claude.ai", "x.claude.ai", "claude.com"):
            with self.subTest(line=line):
                self.refused(self.entries(line + "\n"), "refuses model providers' hosts")

    def test_empty_file_accepted(self):
        self.accepted(self.entries(""))


if __name__ == "__main__":
    unittest.main()
