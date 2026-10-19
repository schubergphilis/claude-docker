# Egress lock through the auth-proxy sidecar

## Why

`--egress-lock` was written when `--api` forwarded the endpoint and token into the agent container and only `--gh` had an auth-proxy sidecar. With the auth-proxy change, `--api` gives the agent `ANTHROPIC_BASE_URL=http://claude-docker-api-proxy:8080` and placeholders, and `--glab` goes through the same sidecar. Unchanged, the lock would pin Claude Code to the real gateway (skipping the sidecar, so the placeholder reaches the gateway), squid would refuse the sidecar's plain-HTTP port, and the agent would have no route to the sidecar's GitLab and API names.

## What Changes

- `--egress-lock` accepts `--api` or `--api-direct`. Under `--api-direct` it works as before.
- Under `--api` the managed settings pin `http://claude-docker-api-proxy:8080`, the sidecar, whose only upstream is the host's `ANTHROPIC_BASE_URL`.
- The auth-proxy sidecar (not only for `--gh`) joins the internal egress network. squid resolves every name it serves to it (`claude-docker-api-proxy`, the GitHub names, the `--glab` host) and allows its own ports for those names only: 8080 for the API proxy, and a `--glab` host's explicit port.
- `CLAUDE_DOCKER_ADD_HOSTS` entries reach squid too, except names the sidecar serves.
- Docs: under `--api` the egress log shows the agent's requests to the sidecar, not a `CONNECT` to the gateway; the sidecar's own upstream connection doesn't pass through squid.

## Capabilities

- `api-egress-policy`: MODIFIED (sidecar composition, managed-settings pin, the `--api` requirement).

## Impact

`run.sh`, `tests/bats/run.bats`, `tests/smoke/egress.sh`, `tests/smoke/assert-in-container.sh`, `tests/bats/egress.bats`, `docs/auth.md`. The `--endpoint-port` smoke cell now runs with `--api-direct`, the only mode in which the agent dials the endpoint itself.

## Follow-up

Route the auth-proxy sidecar's upstream connections through squid too, so the log records the `CONNECT` to the gateway under `--api` as well. Not done here.
