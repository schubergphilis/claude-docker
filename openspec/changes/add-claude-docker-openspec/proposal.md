## Why

The container already hosts `claude-docker/openspec/` artifacts and the repo drives work through OpenSpec-style change proposals, but the `openspec` CLI itself is not installed in the image. Contributors must either install it on the host or bootstrap it ad-hoc inside the container, which breaks the "open the container, everything works" contract that `gh`, `glab`, and `aws` already honour.

## What Changes

- Install `@fission-ai/openspec` globally in the Dockerfile, alongside `@anthropic-ai/claude-code`.
- Pin the version via a new `OPENSPEC_VERSION` build ARG (mirroring the `CLAUDE_CODE_VERSION` pattern) so bumps are explicit and reviewable.
- Use `npm install -g --ignore-scripts` for parity with the existing claude-code install (no lifecycle scripts, predictable layer).
- No credential handling, no `run.sh` flags, no volume mounts — `openspec` is a local-only CLI that reads/writes files under `openspec/` in the workspace.

Not in scope: adding an openspec skill/plugin, scaffolding `openspec/` in fresh workspaces, or modifying `run.sh`.

## Capabilities

### New Capabilities
- `openspec-cli`: Ship the `openspec` CLI inside the container image at a pinned version so spec-driven workflows work out of the box with no host install.

### Modified Capabilities
<!-- None. `external-cli-tools` scopes itself to auth-bearing CLIs (gh/glab/aws) with credential passthrough; openspec has no credentials and no host state, so a separate capability keeps concerns clean. -->

## Impact

- `claude-docker/Dockerfile`: new `ARG OPENSPEC_VERSION` and an added `npm install -g --ignore-scripts` line (can share the existing claude-code install layer or be a sibling RUN).
- Image size: one additional npm package (~73 deps per install log), negligible vs. the claude-code install.
- `claude-docker/README.md`: mention `openspec` in the list of bundled CLIs.
- No changes to `run.sh`, no new flags, no new mounts, no new env vars.
- Multi-arch: `@fission-ai/openspec` is pure JS on top of Node, so `amd64` and `arm64` builds are unaffected.
