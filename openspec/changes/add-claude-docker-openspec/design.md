## Context

`claude-docker/` already treats `openspec/` artifacts as the source of truth for behavioural change, but the `openspec` CLI itself is only available on contributors' hosts, not inside the container image. Every other CLI the container needs (`claude`, `gh`, `glab`, `aws`) is baked in at pinned versions with sha256 verification where applicable; `openspec` is the odd one out.

The image's existing patterns:
- **npm-backed tools** (`@anthropic-ai/claude-code`): installed via `npm install -g --ignore-scripts` with the version held in a build ARG and no sha256 verify (npm registry is the trust root).
- **Version-ARG convention**: every pinned tool has a `<TOOL>_VERSION` ARG at the top of the Dockerfile, with a comment noting how to refresh the pin.

This change is narrow on purpose: install one more npm-backed tool using the existing pattern. No flags, no mounts, no auth.

## Goals / Non-Goals

**Goals:**
- `openspec --version` succeeds on a fresh `docker build` with no host state.
- Version is pinned via build ARG and reviewable in the same commit as any future bump.
- Multi-arch (`amd64` / `arm64`) builds continue to succeed.
- Install cost (image size + build time) is negligible vs. existing tooling.

**Non-Goals:**
- No credential passthrough or `run.sh` flags (`openspec` has no auth model).
- No workspace scaffolding — `openspec init` stays a manual opt-in per repo.
- No skill/plugin wiring beyond what `~/.claude/skills` already provides via bind-mount.
- No sha256 verify of the tarball — npm install is the precedent set by `@anthropic-ai/claude-code`; introducing package-lock hashing for one package would be inconsistent and add churn.

## Decisions

### Decision: Install via `npm install -g --ignore-scripts`, not a separate toolchain

Mirror the existing `@anthropic-ai/claude-code` line exactly. Rationale:
- Same trust model (npm registry), same flags, same failure modes.
- `--ignore-scripts` keeps install deterministic and avoids running third-party postinstall scripts.
- Alternative considered: pull a tarball from GitHub Releases and sha256 verify like `glab`/`aws`. Rejected because `@fission-ai/openspec` publishes no standalone release asset, only npm; forcing GitHub-tarball consumption means bypassing the maintainer's distribution channel.

### Decision: Add `OPENSPEC_VERSION` ARG, don't inline the version

Every existing pinned tool has a `*_VERSION` ARG. Rationale: greppable, reviewable, consistent with the "bump version + sha in same commit" comment at the top of the Dockerfile (the sha part doesn't apply to npm, but the ARG convention does).

### Decision: Combine with the existing `claude-code` RUN layer, not a new layer

The claude-code install is already an `npm install -g --ignore-scripts`; extend that same RUN to install both packages in one invocation. Rationale:
- One npm cache warm-up, one node_modules layer, smaller image.
- Both packages bump together rarely enough that cache-invalidating the whole layer on an openspec bump is acceptable.
- Alternative considered: keep them in separate RUN layers for independent cache invalidation. Rejected — marginal win, costs an extra layer and duplicates the `npm install` incantation.

### Decision: `openspec-cli` as a new capability, not a requirement under `external-cli-tools`

`external-cli-tools`' purpose statement is scoped to auth-bearing CLIs (`gh`, `glab`, `aws`) with credential passthrough and tmpfs masking. `openspec` has none of that. Rationale: adding it there would muddy the spec's purpose and require contortions to document "no credentials" scenarios. A separate, minimal capability keeps each spec single-concern.

## Risks / Trade-offs

- [npm registry outage at build time] → Mitigation: accepted risk; identical to the existing claude-code install. No new exposure.
- [Upstream package renames or becomes unmaintained] → Mitigation: pin via ARG means we can swap the package name in one diff; nothing else in the image depends on it.
- [Package ships a postinstall that would have added PATH/shell integration] → Mitigation: `--ignore-scripts` deliberately skips it. If shell completion is needed later, add `openspec completion` explicitly in a follow-up change rather than trusting arbitrary postinstall.
- [Version drift between host and container] → Accepted. The container pin is the source of truth for in-container work; host version only affects out-of-container scaffolding.

## Migration Plan

No migration. This is a pure addition:
1. Bump the Dockerfile (new ARG + extended RUN).
2. Rebuild the image (`docker build -t claude-code:local ./claude-docker`).
3. Existing containers pick up the change on their next rebuild; no volume state is affected.

Rollback: revert the Dockerfile change and rebuild. No persisted state depends on the CLI being present.

## Open Questions

- Which `OPENSPEC_VERSION` to pin at merge time? Current latest is `1.3.0`; any bump between now and merge should use whatever is current, not retroactively pick `1.3.0`.
