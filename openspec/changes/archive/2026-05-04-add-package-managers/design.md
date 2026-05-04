## Context

The base image already ships `claude-code`, `openspec`, `gh`, `glab`, and `aws v2` — clearly a "user-tier batteries-included" posture, not a minimal one. Two gaps come up constantly in practice: there's no Python package manager (and `pip` is broken under PEP 668 on bookworm without `--break-system-packages`), and there's no fast Node package manager beyond the npm that ships with the base image.

PR #17 added `CLAUDE_DOCKER_IMAGE` so child images can extend the base without forking `run.sh`. That settles the question for *project-specific* tooling (Rust/Go toolchains, project-pinned linters, etc.). But it also sharpens the line for *user-tier* tools: if every user needs them, bundle; if only some projects need them, extend.

`uv` and `pnpm` both fall on the "every user" side:
- **uv** replaces pip/pipx/virtualenv/poetry with one statically-linked binary; `uvx` runs arbitrary PyPI tools without an environment juggling step. This is the only practical way to get Python tooling into the image given the bookworm + PEP 668 constraint.
- **pnpm** is a near-universal Node-side preference and the user's gprefs already require `pnpm` over `npm` and `pnpm dlx` over `npx`. Adding it costs ~10 MB and one line in the existing `npm install -g` block.

## Goals / Non-Goals

**Goals:**
- Ship `uv`, `uvx`, `pnpm`, `pnpx` on the default PATH for both amd64 and arm64.
- Match the existing pin-and-verify hardening pattern (versions in `ARG`, sha256 where the ecosystem supports it, `--ignore-scripts` preserved for npm installs).
- Document the new runtime-fetch surface in the threat model so a reader can decide whether the trade-off is acceptable.
- Keep the change purely additive — no breaking changes, no behavioural shifts in unrelated parts of the image.

**Non-Goals:**
- Closing the npm-registry trust gap that already exists for `claude-code` and `openspec` installs. Filed as FU1 to fix consistently across all three npm-backed installs in a follow-up.
- Adding end-to-end attestation verification (`gh attestation verify`) for binary downloads. Filed as FU2; would touch AWS CLI and glab too.
- Adding language runtimes (rustup/cargo, go, ruby). Project-specific — belongs in child images via PR #17's pattern.
- Bundling `yarn` or `bun`. No demand; smaller surface = better.

## Decisions

### Decision 1: install `uv` from the prebuilt static binary tarball, not via `pip` or Astral's installer script

**Choice:** Download `uv-${ARCH}-unknown-linux-gnu.tar.gz` from `github.com/astral-sh/uv/releases/download/${UV_VERSION}/`, verify against ARG-pinned sha256, extract to a scratch dir, then `install -m 0755 .../uv .../uvx /usr/local/bin/`.

**Why:**
- Matches the existing AWS CLI v2 block exactly (curl + sha256 ARG + arch case statement).
- `uv` is statically linked against glibc — bookworm-slim is glibc, so the `gnu` variant works with zero extra dependencies.
- The tarball ships both `uv` and `uvx` in one archive, no second install step.
- Avoids `pip --break-system-packages` and avoids running Astral's curl-pipe-bash installer.

**Rejected alternatives:**
- `pip install uv`: needs Python in the image, hits PEP 668, defeats the point of having `uv`.
- Astral's `curl https://astral.sh/uv/install.sh | sh`: implicit trust of an installer script we don't pin or verify.
- musl variant (`-musl.tar.gz`): bookworm-slim is glibc, musl binaries silently fail at runtime with cryptic dynamic-loader errors.

### Decision 2: pin uv's sha256 in `ARG` declarations, not by fetching the `.sha256` sidecar at build time

**Choice:** Two `ARG`s per arch (`UV_SHA256_X86_64`, `UV_SHA256_AARCH64`) committed to the Dockerfile, bumped in lockstep with `UV_VERSION`.

**Why:**
- Astral publishes a `.sha256` sidecar alongside each release asset, but it's served from the same release URL. A compromised release artifact + sidecar swap together would still verify.
- Pinning the hash in `ARG` form puts it in version control: a malicious post-pin artifact swap shows up in `sha256sum -c` output at build time.
- This is the same trust model as the existing `glab` and AWS CLI v2 blocks (both use ARG-pinned hashes pasted from upstream release pages).

**Acknowledged residual:** the human pasting the hash trusts upstream's release page at the moment of the bump. Closing this gap end-to-end requires `gh attestation verify` — filed as FU2, applies uniformly to uv + glab + AWS CLI.

### Decision 3: install `pnpm` by appending to the existing `npm install -g --ignore-scripts` line

**Choice:** Add `"pnpm@${PNPM_VERSION}"` to the existing RUN block alongside `claude-code` and `openspec`. Single layer, single trust surface, `--ignore-scripts` inherits automatically.

**Why:**
- Matches the existing precedent for the most-privileged package in the image (`claude-code` itself). If we trust npm to deliver claude-code, trusting it for pnpm doesn't move the needle.
- `--ignore-scripts` is non-negotiable and stays on the same line — defense against lifecycle-script execution at install time.
- Single-layer install keeps the image lean and the build cache coherent.

**Rejected alternative — corepack:**
- `corepack prepare pnpm@X.Y.Z --activate` pins by *version* only. Integrity hashes only kick in when a `packageManager` field with a hash is present (typically in a project's package.json) — not the case during a Docker build. So corepack is strictly *weaker* than `npm install` here, which at least does npm's internal sha512 check against the registry manifest.
- Adds an extra `corepack enable` step. Diverges from the established single-RUN convention.
- Net: more complexity, weaker integrity, no win.

**Acknowledged residual:** npm-registry trust gap (no Dockerfile-layer integrity pin). This *carries forward* the existing posture for claude-code/openspec; it does not introduce a new gap. Filed as FU1 to fix consistently across all three installs.

### Decision 4: pin `pnpm` to 10.33.2, not the newer 11.0.1

**Choice:** `PNPM_VERSION=10.33.2`.

**Why:**
- pnpm 11.0.1 was released two days ago (2026-04-29) but npm has not promoted it to the `latest` tag yet — a deliberate hold while the maintainers stabilize the v11 line (pure-ESM distribution, SQLite-backed store index).
- Image production builds should track the `latest` tag, not the absolute newest release.
- A bump to 11.x after npm promotes it can ship as a separate, tiny PR.

### Decision 5: no `yarn`, no `bun`, no language runtimes

**Choice:** Reject all of the above for this change.

**Why:**
- **Yarn**: v1 is unmaintained; v2+ has a different API and most projects have migrated away. Negative ROI to bundle.
- **Bun**: a runtime, not a peer of pnpm. Bundles its own JS engine; would significantly grow the image. No demand established.
- **rustup/cargo, go, ruby toolchains**: project-specific. PR #17's child-image pattern is the right home for these.

## Risks / Trade-offs

**[R1] uvx newly enables PyPI code execution under `--yolo`** → Container's existing controls (`--cap-drop ALL`, `IS_SANDBOX=1`, `no-new-privileges`, no host bind-mounts to sensitive paths) bound the blast radius to what `npx` could already do (npm-side execution was already reachable via the base Node.js image). Wider menu of registries, same trust model. Documented explicitly in the README's Threat model section.

**[R2] npm-registry compromise of pinned `pnpm@10.33.2`** → Same risk profile as the existing `claude-code` and `openspec` installs. `--ignore-scripts` blocks lifecycle-script execution at install time but the resulting binary on PATH is whatever the registry served. Mitigation deferred to FU1 (integrity pinning across all npm installs).

**[R3] uv release CDN compromise** → ARG-pinned sha256 catches post-pin artifact swaps; the bump-time trust window remains. Mitigation deferred to FU2 (`gh attestation verify`).

**[R4] musl/glibc confusion on the wrong base image** → Locked by using the `gnu` variant explicitly in the URL pattern. Comment in Dockerfile makes this non-obvious choice obvious. If someone bumps the base image to an Alpine-derived one, the build will fail loudly at sha256 mismatch (different binary entirely), not silently at runtime.

**[R5] Image size growth (~40 MB)** → Acceptable. Base is already ~400 MB; `uv` (~30 MB) and `pnpm` (~10 MB) are proportionate to their value. If size becomes a concern, the answer is a slim variant of the image, not pruning user-tier tools.

## Migration Plan

No migration needed — purely additive. Existing `claude-docker` invocations behave identically; new tools simply become available on PATH. Users rebuild the image (`docker build -t claude-code:local ./claude-docker`) once after the change lands.

Rollback: revert the Dockerfile changes; rebuild. No data migration, no persisted state interaction.

## Open Questions

None blocking. FU1 and FU2 are tracked as out-of-scope follow-ups in the proposal.
