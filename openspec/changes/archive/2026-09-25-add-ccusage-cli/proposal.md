## Why

`host-config-parity` forwards the host statusline script so the container looks like the host. A common statusline segment shows token usage or monthly spend through `ccusage`. The image does not ship it, so the script's `command -v ccusage` check fails and that segment silently disappears in the container.

## What Changes

- Install the `ccusage` npm package in the existing `npm install -g --ignore-scripts` layer, pinned in a generated `pins/ccusage.env` fragment.
- Register `ccusage` in `update_pins.py` as an npm tool with a version probe, so pin refresh, the soak gate, CI's `npm audit signatures` and CI's runtime version check cover it like the other npm tools.
- Set the executable bit on ccusage's native binary at build time and assert `ccusage --version` in the build. npm installs the binary as `0644`, and the launcher's first-run `chmod` fails for the non-root UID the container runs as.
- Document `ccusage` in the README's tool and npm-provenance lists, including that it only sees container sessions.

Not in scope: forwarding host transcripts (`~/.claude/projects/`) so `ccusage` reports host usage too. That would expose every host session's content to the container.

## Capabilities

### New Capabilities
- `ccusage-cli`: ship the `ccusage` CLI at a pinned version with no credential or `run.sh` surface.

### Modified Capabilities
- `version-pin-refresh`: the list of version-only npm tools includes `ccusage`.
- `package-managers`: the shared `--ignore-scripts` npm invocation includes `ccusage`, and a build-time `chmod` on a package's file must be named with its reason.

## Impact

- `Dockerfile`: `COPY` and source `pins/ccusage.env` in the npm layer; one package added to the install; `chmod` plus a version assertion.
- `update_pins.py`, `tests/test_update_pins.py`: new `Tool` entry and fragment lines.
- `pins/ccusage.env`: new generated fragment.
- `README.md`: tool list, npm provenance lists, statusline note.
- Image size: about 4 MB for the one native binary for the build's architecture. The other platform binaries are optional dependencies for other OS/CPU pairs, so npm skips them.
- No changes to `run.sh` or `entrypoint.sh`.
