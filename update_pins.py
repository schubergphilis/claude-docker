#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Regenerate the version/sha256 pins under pins/.

For each automated tool this selects the highest STABLE version that is already
older than the soak window (default 7 days), downloads the artifact(s) for BOTH
amd64 and arm64, computes the sha256(s), and writes pins/<tool>.env. Selecting a
version that has already survived the soak window bakes the supply-chain soak
into the *selection* — the resulting image is safe to use the moment it is built
(see openspec/changes/automate-version-pins/design.md).

The pins/ fragments are the Dockerfile's source of truth: it COPYs + sources
them. Nothing here ever edits the Dockerfile. nodejs and the base-image digest
stay manual on purpose and are surfaced as reminders.

Usage:
  uv run update_pins.py                      refresh all automated tools (soak = 7d)
  uv run update_pins.py --soak 14            use a 14-day soak window
  uv run update_pins.py --block-major-bumps  stay within each tool's current major
  uv run update_pins.py --pin uv=0.12.3      force a specific version (bypasses soak)
  uv run update_pins.py --pin pnpm=11.5.3 --pin uv=0.12.3   multiple overrides

Honors GITHUB_TOKEN / GH_TOKEN (raises the GitHub API rate limit) when set.
Stdlib only — no third-party packages (a supply-chain tool keeps its own trusted
base minimal; `dependencies = []` above makes that visible and enforced).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path

REPO_DIR = Path(__file__).resolve().parent
PINS_DIR = REPO_DIR / "pins"
DOCKERFILE = REPO_DIR / "Dockerfile"
USER_AGENT = "update_pins.py (claude-docker)"
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")

# tool registry: (name, kind, ref). ref meaning is kind-specific:
#   npm    -> npm package name        github -> owner/repo (releases)
#   gitlab -> owner/repo (releases)   awscli -> special-cased (tag date + CDN)
TOOLS = [
    ("claude-code", "npm", "@anthropic-ai/claude-code"),
    ("openspec", "npm", "@fission-ai/openspec"),
    ("pnpm", "npm", "pnpm"),
    ("uv", "github", "astral-sh/uv"),
    ("glab", "gitlab", "gitlab-org/cli"),
    ("tfenv", "github", "tfutils/tfenv"),
    ("awscli", "awscli", "aws/aws-cli"),
]


# ---- HTTP (https-only, bounded redirects) ---------------------------------
class _HTTPSOnlyRedirect(urllib.request.HTTPRedirectHandler):
    """Reject redirects to non-https targets and bound the chain — the urllib
    analogue of curl --proto-redir '=https' --max-redirs 5."""

    max_redirections = 5

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if not newurl.lower().startswith("https://"):
            raise urllib.error.URLError(f"refusing non-https redirect to {newurl}")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


_OPENER = urllib.request.build_opener(_HTTPSOnlyRedirect)


def _open(url: str, headers: dict | None = None):
    if not url.lower().startswith("https://"):
        raise ValueError(f"refusing non-https URL: {url}")
    hdrs = {"User-Agent": USER_AGENT}
    if headers:
        hdrs.update(headers)
    return _OPENER.open(urllib.request.Request(url, headers=hdrs), timeout=30)


def http_bytes(url: str, headers: dict | None = None) -> bytes:
    with _open(url, headers) as r:
        return r.read()


def get_json(url: str, headers: dict | None = None):
    return json.loads(http_bytes(url, headers).decode())


def gh_headers() -> dict:
    tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    return {"Authorization": f"Bearer {tok}"} if tok else {}


def sha256_of_download(url: str) -> str:
    try:
        return hashlib.sha256(http_bytes(url)).hexdigest()
    except urllib.error.HTTPError as e:
        raise RuntimeError(f"download failed ({e.code}): {url}") from e


# ---- version helpers (pure) -----------------------------------------------
def parse_dt(ts: str) -> datetime:
    """Parse an ISO-8601 timestamp (optional fractional seconds / trailing Z)
    into a timezone-aware UTC datetime."""
    dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def _semver_key(v: str) -> tuple[int, int, int]:
    a, b, c = v.split(".")
    return (int(a), int(b), int(c))


def max_stable(versions) -> str:
    stable = [v for v in versions if SEMVER_RE.match(v)]
    return max(stable, key=_semver_key) if stable else ""


def newest_within_major(versions, major: str) -> str:
    within = [v for v in versions if SEMVER_RE.match(v) and v.split(".")[0] == major]
    return max(within, key=_semver_key) if within else ""


def major_of(v: str) -> str:
    return v.split(".")[0] if v else ""


def is_major_bump(old: str, new: str) -> bool:
    return bool(old) and major_of(old) != major_of(new)


# ---- candidate listing: returns [(version, iso8601), ...] -----------------
def candidates(kind: str, ref: str):
    if kind == "npm":
        enc = ref.replace("/", "%2F")
        doc = get_json(f"https://registry.npmjs.org/{enc}")
        published = doc.get("versions", {})  # live set (excludes yanked/unpublished)
        return [
            (v, t)
            for v, t in doc.get("time", {}).items()
            if SEMVER_RE.match(v) and v in published
        ]
    if kind == "github":
        rel = get_json(f"https://api.github.com/repos/{ref}/releases?per_page=100", gh_headers())
        return [
            (r["tag_name"].lstrip("v"), r["published_at"])
            for r in rel
            if not r["draft"] and not r["prerelease"]
        ]
    if kind == "gitlab":
        enc = ref.replace("/", "%2F")
        rel = get_json(f"https://gitlab.com/api/v4/projects/{enc}/releases?per_page=100")
        return [(r["tag_name"].lstrip("v"), r["released_at"]) for r in rel]
    raise ValueError(f"unknown kind: {kind}")


def aws_cli_tags():
    """Paginate the aws-cli tags endpoint (a single page=100 could push the
    newest v2 tags off page 1). Stop on a short page or a 10-page safety cap."""
    names = []
    for page in range(1, 11):
        body = get_json(
            f"https://api.github.com/repos/aws/aws-cli/tags?per_page=100&page={page}",
            gh_headers(),
        )
        if not body:
            break
        names += [t["name"] for t in body]
        if len(body) < 100:
            break
    return names


# ---- resolution ------------------------------------------------------------
class Result:
    __slots__ = ("status", "version", "age", "held", "held_age", "blocked_major")

    def __init__(self):
        self.status = ""            # UPDATE | NOCHANGE | OVERRIDE | ERROR
        self.version = ""
        self.age = ""
        self.held = ""
        self.held_age = ""
        self.blocked_major = ""


def _age_days(now: datetime, iso: str) -> str:
    try:
        return f"{(now - parse_dt(iso)).days}d"
    except Exception:
        return "?"


def resolve(name, kind, ref, current, soak_days, block_major, overrides) -> Result:
    r = Result()
    if name in overrides:
        r.version, r.status = overrides[name], "OVERRIDE"
        # Binary tools self-validate (a bad version 404s at hash time). npm tools
        # never download here, so validate a typo'd --pin against the registry.
        if kind == "npm" and not npm_version_exists(ref, r.version):
            raise RuntimeError(f"{ref}@{r.version} is not published on the npm registry")
        return r

    if kind == "awscli":
        return resolve_awscli(current, soak_days)

    now, soak = now_utc(), timedelta(days=soak_days)
    cand = candidates(kind, ref)
    if not cand:
        raise RuntimeError(f"no candidate versions for {name}")

    soaked = [v for v, iso in cand if now - parse_dt(iso) >= soak]
    in_soak = [v for v, iso in cand if now - parse_dt(iso) < soak]
    iso_of = {v: iso for v, iso in cand}

    max_all = max_stable(soaked)
    if not max_all:
        raise RuntimeError(f"no soaked version for {name}")
    chosen = max_all

    if block_major and current and major_of(max_all) != major_of(current):
        chosen = newest_within_major(soaked, major_of(current)) or current
        r.blocked_major = max_all

    r.version = chosen
    r.age = _age_days(now, iso_of.get(chosen, ""))

    # held = highest in-soak version newer than the pick (soak visibly at work)
    held = max_stable(in_soak + [chosen])
    if held and held != chosen:
        r.held, r.held_age = held, _age_days(now, iso_of.get(held, ""))

    r.status = "NOCHANGE" if chosen == current else "UPDATE"
    return r


def resolve_awscli(current, soak_days) -> Result:
    # aws-cli tags carry no date; walk newest-semver-first fetching each tag's
    # commit date until one clears the soak (bounded: usually 1-2 calls). The
    # ^2. filter locks this to v2, so --block-major-bumps is implicitly a no-op.
    r = Result()
    now, soak = now_utc(), timedelta(days=soak_days)
    tags = sorted(
        (t for t in aws_cli_tags() if re.match(r"^2\.\d+\.\d+$", t)),
        key=_semver_key,
        reverse=True,
    )
    for tag in tags:
        commit = get_json(f"https://api.github.com/repos/aws/aws-cli/commits/{tag}", gh_headers())
        dt = parse_dt(commit["commit"]["committer"]["date"])
        if now - dt >= soak:
            r.version, r.age = tag, f"{(now - dt).days}d"
            r.status = "NOCHANGE" if tag == current else "UPDATE"
            return r
        if not r.held:
            r.held, r.held_age = tag, f"{(now - dt).days}d"
    raise RuntimeError("no soaked aws-cli version found")


def npm_version_exists(pkg: str, version: str) -> bool:
    enc = pkg.replace("/", "%2F")
    try:
        return version in get_json(f"https://registry.npmjs.org/{enc}").get("versions", {})
    except urllib.error.HTTPError:
        return False


# ---- fragment writing ------------------------------------------------------
def _arch_url_sha_lines(prefix: str, urls: dict) -> list[str]:
    """Emit each arch's resolved URL immediately followed by the sha256 of the
    bytes at that URL. The Dockerfile sources both and curls "$..._URL_<arch>",
    so the committed hash provably covers the exact artifact the build fetches —
    the download URL is single-sourced here instead of being reconstructed
    independently on the build side, so the two can no longer drift apart."""
    lines = []
    for arch, url in urls.items():
        lines.append(f"{prefix}_URL_{arch}={url}")
        lines.append(f"{prefix}_SHA256_{arch}={sha256_of_download(url)}")
    return lines


def fragment_lines(name: str, v: str) -> list[str]:
    """Return the "VAR=value" lines for a tool's pins/<name>.env (downloading +
    hashing binary artifacts). npm tools are version-only (npm install verifies
    the registry-advertised dist.integrity; CI runs `npm audit signatures`).
    Binary tools emit the resolved download URL next to its sha256 so the build
    fetches and verifies from one committed source of truth (_arch_url_sha_lines)."""
    if name == "claude-code":
        return [f"CLAUDE_CODE_VERSION={v}"]
    if name == "openspec":
        return [f"OPENSPEC_VERSION={v}"]
    if name == "pnpm":
        return [f"PNPM_VERSION={v}"]
    if name == "uv":
        base = "https://github.com/astral-sh/uv/releases/download"
        return [f"UV_VERSION={v}"] + _arch_url_sha_lines("UV", {
            "X86_64": f"{base}/{v}/uv-x86_64-unknown-linux-gnu.tar.gz",
            "AARCH64": f"{base}/{v}/uv-aarch64-unknown-linux-gnu.tar.gz",
        })
    if name == "glab":
        base = f"https://gitlab.com/gitlab-org/cli/-/releases/v{v}/downloads"
        return [f"GLAB_VERSION={v}"] + _arch_url_sha_lines("GLAB_DEB", {
            "AMD64": f"{base}/glab_{v}_linux_amd64.deb",
            "ARM64": f"{base}/glab_{v}_linux_arm64.deb",
        })
    if name == "awscli":
        base = "https://awscli.amazonaws.com"
        return [f"AWSCLI_VERSION={v}"] + _arch_url_sha_lines("AWSCLI", {
            "X86_64": f"{base}/awscli-exe-linux-x86_64-{v}.zip",
            "AARCH64": f"{base}/awscli-exe-linux-aarch64-{v}.zip",
        })
    if name == "tfenv":
        url = f"https://github.com/tfutils/tfenv/archive/refs/tags/v{v}.tar.gz"
        return [f"TFENV_VERSION={v}", f"TFENV_URL={url}",
                f"TFENV_SHA256={sha256_of_download(url)}"]
    raise ValueError(f"unknown tool: {name}")


def write_fragment(stage: Path, name: str, version: str):
    header = (
        f"# Generated by update_pins.py — do not edit by hand "
        f"(use: update_pins.py --pin {name}=<version>).\n"
    )
    (stage / f"{name}.env").write_text(header + "\n".join(fragment_lines(name, version)) + "\n")


def read_current(name: str) -> str:
    f = PINS_DIR / f"{name}.env"
    if not f.exists():
        return ""
    for line in f.read_text().splitlines():
        if "_VERSION=" in line:
            return line.split("=", 1)[1]
    return ""


# ---- reminders (manual pins) ----------------------------------------------
def ubuntu_current_digest() -> str:
    """Current multi-arch index digest of ubuntu:26.04 from the registry (no
    docker needed). Best-effort: returns '' on any failure."""
    try:
        token = get_json(
            "https://auth.docker.io/token?service=registry.docker.io"
            "&scope=repository:library/ubuntu:pull"
        )["token"]
        with _open(
            "https://registry-1.docker.io/v2/library/ubuntu/manifests/26.04",
            {
                "Authorization": f"Bearer {token}",
                "Accept": "application/vnd.oci.image.index.v1+json, "
                "application/vnd.docker.distribution.manifest.list.v2+json",
            },
        ) as r:
            return r.headers.get("Docker-Content-Digest", "")
    except Exception:
        return ""


def print_reminders():
    print("\n  ⚠ needs your eyes (manual pins) ─────────────────────────────")
    node = ""
    base = ""
    for line in DOCKERFILE.read_text().splitlines():
        if line.startswith("ARG NODE_VERSION="):
            node = line.split("=", 1)[1]
        m = re.search(r"@(sha256:[0-9a-f]+)", line)
        if line.startswith("FROM ubuntu") and m:
            base = m.group(1)
    print(f"  ⚠ nodejs        pinned {node or '?'}  — bump via the NodeSource note in the Dockerfile")
    cur = ubuntu_current_digest()
    if cur and cur != base:
        print(f"  ⚠ ubuntu base   pinned {base[:19]}…  current tag → {cur[:19]}…  (DIFFERS — review)")
    elif cur:
        print(f"  ⚠ ubuntu base   pinned {base[:19]}…  (matches current ubuntu:26.04 tag)")
    else:
        print(f"  ⚠ ubuntu base   pinned {base[:19]}…  (could not resolve current tag digest)")


# ---- main ------------------------------------------------------------------
def parse_args(argv):
    p = argparse.ArgumentParser(
        prog="update_pins.py", description="Regenerate soak-aware version pins under pins/."
    )
    p.add_argument("--soak", type=int, default=7, metavar="DAYS",
                   help="soak window in days (default: 7)")
    p.add_argument("--block-major-bumps", action="store_true",
                   help="stay within each tool's current major version")
    p.add_argument("--pin", action="append", default=[], metavar="TOOL=VERSION",
                   help="force a specific version (bypasses soak); repeatable")
    args = p.parse_args(argv)
    if args.soak < 0:
        p.error("--soak must be a non-negative integer")
    overrides = {}
    tool_names = {name for name, _, _ in TOOLS}
    for kv in args.pin:
        if "=" not in kv or not kv.split("=", 1)[1]:
            p.error(f"--pin expects TOOL=VERSION (got '{kv}')")
        k, v = kv.split("=", 1)
        if k not in tool_names:
            p.error(f"--pin: unknown tool '{k}' (choose from: {', '.join(sorted(tool_names))})")
        if k in overrides:
            p.error(f"--pin: '{k}' given more than once")
        overrides[k] = v
    return args, overrides


def main(argv=None) -> int:
    args, overrides = parse_args(sys.argv[1:] if argv is None else argv)
    print(f"update_pins  (soak window: {args.soak} days)")
    print("  resolving ──────────────────────────────────────────────────")

    stage = Path(tempfile.mkdtemp(prefix=".pins-stage.", dir=REPO_DIR))
    try:
        rows = []
        for name, kind, ref in TOOLS:
            current = read_current(name)
            try:
                r = resolve(name, kind, ref, current, args.soak, args.block_major_bumps, overrides)
            except Exception as e:  # noqa: BLE001 — any failure aborts, pins untouched
                print(f"  ✗ {name}: {e} — aborting, pins/ left untouched", file=sys.stderr)
                return 1
            if r.status in ("UPDATE", "OVERRIDE", "NOCHANGE"):
                try:
                    write_fragment(stage, name, r.version)
                except Exception as e:  # noqa: BLE001
                    print(f"  ✗ {name}: {e} — aborting, pins/ left untouched", file=sys.stderr)
                    return 1
            rows.append((name, current, r))
            print(f"  … {name}")

        # commit staged fragments — os.replace is an atomic per-file rename
        for f in stage.glob("*.env"):
            os.replace(f, PINS_DIR / f.name)
    finally:
        shutil.rmtree(stage, ignore_errors=True)

    print("\n  results ────────────────────────────────────────────────────")
    for name, current, r in rows:
        if r.status == "UPDATE":
            flag = "  ⬆ MAJOR" if is_major_bump(current, r.version) else ""
            print(f"  ✓ {name:<12} {current} → {r.version}   ({r.age}){flag}")
        elif r.status == "OVERRIDE":
            print(f"  ◆ {name:<12} {current} → {r.version}   (override, soak bypassed)")
        elif r.status == "NOCHANGE":
            print(f"  • {name:<12} {current}   unchanged (already newest soaked)")
        if r.held:
            print(f"      ↳ {r.held} available but inside soak ({r.held_age}) — held")
        if r.blocked_major:
            print(f"      ↳ {r.blocked_major} available but blocked by --block-major-bumps (major)")

    print_reminders()
    print("\n  wrote pins/*.env — review the diff, build to test, then commit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
