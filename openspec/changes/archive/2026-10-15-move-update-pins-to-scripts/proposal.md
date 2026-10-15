## Why

`update_pins.py` is the only maintainer tool at the repository root. The other two (`audit-npm-pins.sh`, `verify-pinned-versions.sh`) are in `scripts/`, and both call it. Moving it there leaves the root for the user entry points (`run.sh`, `claude-docker.ps1`) and the image files (`Dockerfile`, `entrypoint.sh`).

## What Changes

- `update_pins.py` moves to `scripts/update_pins.py`. It still runs from the repository root (`uv run scripts/update_pins.py`, `python3 scripts/update_pins.py`), and its paths (`pins/`, `Dockerfile`, the `.pins-stage.*` staging dir) still resolve against the root.
- Every invocation moves with it: `pins-updater.yml`, `scripts/audit-npm-pins.sh`, `scripts/verify-pinned-versions.sh`, `docs/maintenance.md`, the Dockerfile's pin comments, the generated `pins/*.env` headers (`use: scripts/update_pins.py --pin …`), and the unit tests' import path.
- Mentions by name only stay as they are.

## Capabilities

- `go-toolchain`: MODIFIED, scenario commands only.
- `version-pin-refresh`: MODIFIED, scenario commands only.

## Impact

No behaviour change. The pin logic, the report and the generated pin values are unchanged.
