## Why

Some networks have no usable DNS for the forge hosts (GitHub, GitLab, Azure
DevOps Server). On the host that is fixed with `/etc/hosts` entries, but a
container inherits the host's resolver, not its `/etc/hosts`, and the runtime
regenerates `/etc/hosts` at start. `run.sh` passes no runtime flags through, and
the agent runs unprivileged, so `git push` over HTTPS and `gh` / `glab` / `az`
fail on name resolution with no workaround. Issue #160.

## What Changes

- New env var `CLAUDE_DOCKER_ADD_HOSTS="host:ip[,host:ip…]"`. Each entry becomes
  an `--add-host` on the agent container and on the `--gh` sidecar.
- Under an active `--gh` sidecar, entries for `github.com`, `api.github.com` and
  `uploads.github.com` are skipped for the agent with a warning: those must keep
  resolving to the sidecar.
- A malformed entry exits 1 before any container starts.

## Capabilities

- `container-runtime`: ADDED *Static host entries for networks without DNS*.
- `cli-help`: MODIFIED *Help output enumerates every wrapper flag*
  (`CLAUDE_DOCKER_ADD_HOSTS`).

## Impact

- `run.sh`, `docs/usage.md`, `tests/bats/run.bats`. No image change.
