## Why

Raised as [issue #45](https://github.com/schubergphilis/claude-docker/issues/45).

CI proves that a pinned tool *installs*, never that it *runs*. `docker-build`
fails if an install step exits non-zero, and the supply-chain audit step proves
each npm tarball is signed and soaked — but nothing invokes the installed CLI.
The one exception is `claude-code`, which gets a runtime assertion
(`.github/workflows/ci.yml:114-124`) because 2.1.x ships its real binary as a
per-arch optional npm dependency and `--ignore-scripts` can leave `claude` a
non-functional stub (`Dockerfile:211-217`).

That failure mode is narrow; the gap it exposes is not. Of the seven tools in
`update_pins.py`'s `TOOLS` registry, six — `openspec`, `pnpm`, `uv`, `glab`,
`tfenv`, `awscli` — are never executed anywhere in CI. `pins-updater.yml` bumps a
pin unattended, the install still exits 0, no cell invokes the tool, and an image
shipping a broken or version-mismatched CLI merges on green. `openspec-cli`
already *requires* the CLI to "report that same version at runtime" and nothing
enforces it.

## What Changes

- Add `--list-tools` to `update_pins.py`: one TSV row per tool in `TOOLS`,
  carrying the pinned version plus the two things a caller needs to check it —
  the argv to probe the tool with, and the rule for extracting a version from
  that probe's output.
- Extend the `TOOLS` registry entries with those two fields. Tool version output
  formats are not uniform (`11.23.0`, `uv 0.12.5 (aarch64-…)`,
  `aws-cli/2.36.29 Python/…`), so a single string template cannot cover them and
  the per-tool rule lives with the tool it describes.
- Replace `ci.yml`'s claude-code-only smoke step with a loop over `--list-tools`,
  running each probe against the already-built `claude-docker:ci` image and
  asserting the extracted version equals the pinned one. Fail-closed in the same
  shape as the existing audit step: the list is captured with `$(...)` before the
  loop, never consumed through a process substitution whose non-zero exit bash
  drops.
- Cover the new mode in `tests/test_update_pins.py`, including that every
  registry entry's extraction rule actually matches its tool's real output.

Not in scope: the manually-pinned Dockerfile `ARG`s (`nodejs`, `task`, `go`, the
base-image digest). They are a different mechanism, `pins-updater.yml` already
routes them to human review, and two of them cannot be soak-gated at all. Also
not in scope: changing the Dockerfile, the image contents, `smoke/`, or the
existing `--list-npm-tools` contract — the supply-chain audit step keeps
consuming it unchanged. A mismatch fails CI; nothing is auto-remediated.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `version-pin-refresh`: adds a requirement that a pinned tool is verified to
  report its pinned version when executed in the built image, and that the tool
  registry — not CI — owns how each tool is probed. Additive; no existing
  requirement changes.

## Impact

- `update_pins.py` — `TOOLS` entries gain a probe and an extraction rule; new
  `--list-tools` early-return mode alongside `--list-npm-tools`.
- `.github/workflows/ci.yml` — the `docker-build` job's single claude-code smoke
  step becomes a loop over every automated pin.
- `tests/test_update_pins.py` — coverage for the new mode and the registry's
  extraction rules.
- `README.md` — the refresh section describes the new mode in prose as CI-consumed,
  leaving the operator command block alone, where its sibling `--list-npm-tools`
  is likewise absent.
- No change to the Dockerfile, the built image, `smoke/`, `run.sh`, or
  `entrypoint.sh`. Nothing a container user can observe changes; the audience is
  a contributor bumping a pin.
