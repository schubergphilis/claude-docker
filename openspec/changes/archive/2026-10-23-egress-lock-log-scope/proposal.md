# Egress lock: check the saved log, and say what it covers

## Why

Review of #101, items 2 and 3 of both stefanwb and dtump:

- **The log copy isn't checked** (`run.sh:705`). `egress_save_log` runs `docker logs … || true` and then prints "egress log saved" either way. If the copy fails, or the engine's log driver has rotated the log (`max-size` in `daemon.json`), the saved evidence is empty or truncated with no warning. It is the one artefact the feature exists to produce.
- **The docs promise a complete log, and it isn't.** The agent's `/etc/hosts` maps the auth-proxy sidecar's names (the GitHub hosts, the `--glab` host, `claude-docker-api-proxy`) to the sidecar's address on the internal network. A client that ignores the proxy env, or a project `NO_PROXY`, reaches the sidecar directly and leaves nothing in squid's log; under `--api` that includes the model requests. The sidecar's upstreams are fixed, so the lock holds, but "logs every connection the session makes" (`docs/auth.md`, the `--help` text) and "a connection that bypasses the proxy or its saved log" (`SECURITY.md` scope) don't.

## What Changes

- `egress_save_log` keeps the engine's stderr instead of discarding it, and checks the copy. When the log command fails, or the proxy reached readiness but the copy lacks squid's `Accepting HTTP Socket connections` startup line (the line `run.sh` waited for, so its absence means the start of the log was rotated or dropped), it prints that the log in `<file>` is missing or incomplete, with the reason, instead of "egress log saved". It still writes what it got and the `.meta`, and still never fails the teardown.
- The claim is narrowed rather than the gap closed: squid logs every connection it carries; the agent's only other way off the internal network is the auth-proxy sidecar, whose upstreams are fixed (GitHub, the `--glab` host, `ANTHROPIC_BASE_URL`), and a request made straight to it is in the sidecar's audit log, not squid's. Routing the agent → sidecar hop through squid stays a possible follow-up. `docs/auth.md`, the `--help` text and the `SECURITY.md` scope change accordingly.

## Capabilities

- `api-egress-policy`: MODIFIED (the saved-log requirement), RENAMED and MODIFIED (the network-boundary requirement no longer claims the log is complete).
- `cli-help`: MODIFIED (the `--egress-lock` help line).

## Impact

`run.sh`, `tests/bats/run.bats`, `tests/smoke/egress.sh`, `docs/auth.md`, `SECURITY.md`.
