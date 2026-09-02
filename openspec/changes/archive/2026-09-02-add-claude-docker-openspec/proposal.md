## Why

The repo already treats its `openspec/` artifacts as the source of truth for behavioural change, but the `openspec` CLI itself is not installed in the image. Contributors must either install it on the host or bootstrap it ad-hoc inside the container, which breaks the "open the container, everything works" contract that `gh`, `glab`, and `aws` already honour.

## What Changes

- Install `@fission-ai/openspec` globally in the Dockerfile, alongside `@anthropic-ai/claude-code`.
- Pin the version in the generated `pins/openspec.env` fragment, which the Dockerfile `COPY`s and sources, so the pin is refreshed by `update_pins.py` alongside every other automated tool and never hand-authored. (This first landed as an `ARG OPENSPEC_VERSION`; `automate-version-pins` later migrated every automated pin to `pins/`.)
- Use `npm install -g --ignore-scripts` for parity with the existing claude-code install (no lifecycle scripts, predictable layer).
- No credential handling, no `run.sh` flags, no volume mounts — `openspec` is a local-only CLI that reads/writes files under `openspec/` in the workspace.

Not in scope: adding an openspec skill/plugin, scaffolding `openspec/` in fresh workspaces, or modifying `run.sh`.

## Capabilities

### New Capabilities
- `openspec-cli`: Ship the `openspec` CLI inside the container image at a pinned version so spec-driven workflows work out of the box with no host install.

Deliberately narrow: the pin *mechanism* belongs to `version-pin-refresh` and the npm install hygiene to `package-managers`, so this capability asserts only that `openspec` is present at the pinned version and adds no credential or `run.sh` surface.

### Modified Capabilities
<!-- None. `external-cli-tools` scopes itself to auth-bearing CLIs (gh/glab/aws) with credential passthrough; openspec has no credentials and no host state, so a separate capability keeps concerns clean. -->

## Impact

- `Dockerfile`: `COPY pins/openspec.env` and source it in the existing `npm install -g --ignore-scripts` RUN that installs claude-code and pnpm.
- `pins/openspec.env`: the generated pin fragment carrying `OPENSPEC_VERSION`.
- Image size: one additional npm package (~73 deps per install log), negligible vs. the claude-code install.
- `README.md`: mention `openspec` in the list of bundled CLIs.
- No changes to `run.sh`, no new flags, no new mounts, no new env vars.
- Multi-arch: `@fission-ai/openspec` is pure JS on top of Node, so `amd64` and `arm64` builds are unaffected.
