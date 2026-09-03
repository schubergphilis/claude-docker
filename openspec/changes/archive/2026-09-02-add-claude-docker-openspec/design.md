## Context

The repo already treats its `openspec/` artifacts as the source of truth for behavioural change, but the `openspec` CLI itself is only available on contributors' hosts, not inside the container image. Every other CLI the container needs (`claude`, `gh`, `glab`, `aws`) is baked in at pinned versions with sha256 verification where applicable; `openspec` is the odd one out.

The image's existing patterns:
- **npm-backed tools** (`@anthropic-ai/claude-code`): installed via `npm install -g --ignore-scripts`, with no sha256 verify (the npm registry is the trust root).
- **Version-pin convention**: every automated tool's version lives in a generated `pins/<tool>.env` fragment that the Dockerfile `COPY`s and sources immediately before the RUN that consumes it, so the pin is refreshed by `update_pins.py` rather than hand-edited. When this change was first drafted the convention was a `<TOOL>_VERSION` build ARG; `automate-version-pins` replaced it with the fragments, and this design has been refreshed to match.

This change is narrow on purpose: install one more npm-backed tool using the existing pattern. No flags, no mounts, no auth.

## Goals / Non-Goals

**Goals:**
- `openspec --version` succeeds on a fresh `docker build` with no host state.
- The version is carried in a version-controlled `pins/` fragment, so a bump is reviewable in its own diff and generated rather than typed.
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

### Decision: Pin the version in `pins/openspec.env`, not inline in the Dockerfile

Every automated tool's version lives in a generated fragment. Rationale: the pin is resolved and written by `update_pins.py` under the same soak gate as the other tools, it is greppable in one file, and the Dockerfile stays free of literal versions.

Superseded decision, kept for the record: this change originally added an `ARG OPENSPEC_VERSION=1.3.0` to the version-ARG block, which was the convention at the time. `automate-version-pins` migrated all automated pins to `pins/` and removed those ARGs; nothing about openspec drove that migration, and the outcome is strictly better for this capability (a bump no longer requires editing the Dockerfile at all).

### Decision: Combine with the existing `claude-code` RUN layer, not a new layer

The claude-code install is already an `npm install -g --ignore-scripts`; extend that same RUN to install both packages in one invocation. Rationale:
- One npm cache warm-up, one node_modules layer, smaller image.
- Both packages bump together rarely enough that cache-invalidating the whole layer on an openspec bump is acceptable.
- Alternative considered: keep them in separate RUN layers for independent cache invalidation. Rejected — marginal win, costs an extra layer and duplicates the `npm install` incantation.

### Decision: `openspec-cli` as a new capability, not a requirement under `external-cli-tools`

`external-cli-tools`' purpose statement is scoped to auth-bearing CLIs (`gh`, `glab`, `aws`) with credential passthrough and tmpfs masking. `openspec` has none of that. Rationale: adding it there would muddy the spec's purpose and require contortions to document "no credentials" scenarios. A separate, minimal capability keeps each spec single-concern.

Kept minimal for the same reason. Two requirements this change originally carried were dropped:
- *Install uses the existing npm pattern* → re-homed. `package-managers` § "npm-backed installs preserve `--ignore-scripts`" already names `openspec` as sharing the single `npm install -g --ignore-scripts` invocation, so this capability doesn't need to restate it.
- *Builds on amd64 and arm64* → retired outright, not re-homed. `package-managers`' arch requirement (`openspec/specs/package-managers/spec.md`) scopes its assertion to `uv`, `uvx`, `pnpm`, and `pnpx` only — it does not cover `openspec`. Dropping this requirement means no spec asserts anything arch-specific about `openspec` going forward. Accepted because the package is pure JS with no arch-specific artifact of its own to assert about; if that ever changes (e.g. a per-arch optional dependency, the same pattern `claude-code` uses), this capability would need its own arch requirement rather than relying on `package-managers`.

Likewise the pin's "single edit point" guarantee is not restated here: `version-pin-refresh` § "Build consumes fragments without hand-authored pins" already requires that the Dockerfile carry no literal version for any automated tool. Following the precedent that capability sets for the manual pins, each tool's own capability binds it to the mechanism instead of duplicating it, so the rule has exactly one owner.

## Risks / Trade-offs

- [npm registry outage at build time] → Mitigation: accepted risk; identical to the existing claude-code install. No new exposure.
- [Upstream package renames or becomes unmaintained] → Mitigation: the pin lives in one generated fragment, so the package name can be swapped in one diff; nothing else in the image depends on it.
- [Package ships a postinstall that would have added PATH/shell integration] → Mitigation: `--ignore-scripts` deliberately skips it. If shell completion is needed later, add `openspec completion` explicitly in a follow-up change rather than trusting arbitrary postinstall.
- [Version drift between host and container] → Accepted. The container pin is the source of truth for in-container work; host version only affects out-of-container scaffolding.
- [Per-arch verification is asymmetric] → arm64 is verified by the maintainers' local Apple Silicon builds (where the CLI was exercised directly); amd64 by CI's `docker-build` job, which proves the install layer but does not invoke `openspec` itself. Accepted: the package is pure JS on Node, so there is no native artifact to differ per arch. This is the same asymmetry `automate-version-pins` 7.3 records for the image as a whole.

## Migration Plan

No migration. This is a pure addition:
1. Bump the Dockerfile (`COPY` + source the fragment in the existing npm RUN).
2. Rebuild the image (`docker build -t claude-code:local .`).
3. Existing containers pick up the change on their next rebuild; no volume state is affected.

Rollback: revert the Dockerfile change and rebuild. No persisted state depends on the CLI being present.

## Open Questions

None. The pin version is no longer a merge-time decision: `update_pins.py` resolves it under the soak gate and writes `pins/openspec.env` (`1.10.0` at the time of archiving), so it moves on its own schedule with the other automated pins.
