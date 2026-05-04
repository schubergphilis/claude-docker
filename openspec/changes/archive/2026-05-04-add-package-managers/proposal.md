## Why

`uv` (Python) and `pnpm` (Node) are general-purpose, user-tier package managers that almost every Claude Code session reaches for. The current image has none — users either fall back to `pip --break-system-packages` (broken on bookworm) or build a child image just to get `uv`. PR #17's `CLAUDE_DOCKER_IMAGE` override now makes child-image extension the canonical path for *project-specific* tooling, which sharpens the line: bundle the user-tier tools, push project-tier tools (rust/go/ruby toolchains) into child images.

## What Changes

- Install `uv` (Astral, ships with `uvx`) as a pinned static binary tarball with per-arch sha256 verification — same hardening pattern as the existing `glab` and AWS CLI v2 blocks.
- Install `pnpm` by appending it to the existing `npm install -g --ignore-scripts` line alongside `claude-code` and `openspec` — same trust model as those installs.
- Update README:
  - Add `uv`, `uvx`, `pnpm`, `pnpx` to the "Bundled CLIs" line at the top.
  - Add a runtime-fetch bullet to the **Threat model** § noting that `uvx` is a *new* PyPI execution primitive (no Python runtime existed before), while `pnpm dlx` matches the already-reachable `npx` (zero marginal blast radius).
  - Note in the "Extending the image" § (PR #17) that any extra package managers added by child images stack on this surface, not replace it.

## Capabilities

### New Capabilities

- `package-managers`: pinned `uv`/`uvx` (Python) and `pnpm`/`pnpx` (Node) on the default PATH, arch-aware for amd64+arm64. Covers install pinning, sha256 verification where the ecosystem supports it, `--ignore-scripts` enforcement for npm-backed installs, and the runtime-fetch threat-model implications of `uvx`/`pnpm dlx`.

### Modified Capabilities

(none — `external-cli-tools` stays focused on credential-bearing CLIs.)

## Impact

- Files: `Dockerfile`, `README.md`. New spec file `openspec/specs/package-managers/spec.md`.
- Rebuild required (new layer for uv binary; existing npm install layer extended).
- Image-size delta: ~30 MB (uv static binary) + ~10 MB (pnpm via npm). Net ~40 MB on a base that's already ~400 MB.
- Build-time TLS endpoints added: 1 new (`github.com/astral-sh/uv/releases/...`). `registry.npmjs.org` was already trusted.
- Runtime endpoints reachable: PyPI (`pypi.org`, `files.pythonhosted.org`) becomes reachable via `uv`/`uvx`. Documented in threat model.
- No breaking changes — purely additive.

## Out of scope (follow-ups)

- **FU1**: add npm-package integrity pinning (`--integrity=` or committed lockfile) consistently across all three npm-backed installs (claude-code, openspec, pnpm). Closes the registry-trust gap that this change *carries forward but does not introduce*.
- **FU2**: `gh attestation verify` for binary downloads (uv, AWS CLI, glab) for end-to-end provenance. Posture *improvement*, not a regression to fix here.
- Project-specific language runtimes (rustup, go, ruby): use PR #17's child-image pattern.
