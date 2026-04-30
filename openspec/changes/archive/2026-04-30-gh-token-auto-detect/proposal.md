## Why

When `--gh` is passed, `run.sh` only forwards `GH_TOKEN` / `GITHUB_TOKEN` if they are already exported in the host shell. Users who authenticate via the `gh` CLI (which stores the token in the macOS Keychain, not in env vars) get no token in the container and must manually export a variable before every run.

## What Changes

- When `--gh` is set and neither `GH_TOKEN` nor `GITHUB_TOKEN` is present in the environment, `run.sh` SHALL call `gh auth token` on the host to obtain the active token and forward it into the container as `GH_TOKEN`.
- If `gh` is not on the host PATH or `gh auth token` fails (not logged in), the flag continues silently without a token — the user can still authenticate inside the container via `gh auth login` as before.

## Capabilities

### New Capabilities
<!-- None -->

### Modified Capabilities
- `external-cli-tools`: The `--gh` credential opt-in requirement changes — token sourcing now includes a `gh auth token` fallback in addition to env var forwarding.

## Impact

- `claude-docker/run.sh`: the `--gh` env-var forwarding block gains a fallback that shells out to `gh auth token`.
- No Dockerfile changes, no new flags, no new volumes.
- Users without `gh` on their PATH are unaffected (fallback is skipped silently).
