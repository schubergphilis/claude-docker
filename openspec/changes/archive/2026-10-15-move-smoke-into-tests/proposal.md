## Why

The smoke harness (`smoke.sh`, `assert-in-container.sh`) is test code, but it sat in its own top-level `smoke/` folder next to `tests/`. Moving it to `tests/smoke/` puts all test code under `tests/`.

## What Changes

- `smoke/` moves to `tests/smoke/`. `smoke.sh` now finds `run.sh` two levels up. It still copies `assert-in-container.sh` from its own folder.
- The invocations move with it: `ci.yml`'s smoke matrix, `CONTRIBUTING.md` (shellcheck and smoke commands), `docs/maintenance.md`, and the comments that point at it.

## Capabilities

- `go-toolchain`: MODIFIED, scenario path only.

## Impact

No behaviour change: the same cells, the same assertions.
