## Why

The container's environment starts as `ENV_ARGS=(-e TERM)` and no opt-in ever
appends an `ANTHROPIC_*` variable, so a host `export ANTHROPIC_BASE_URL=...` has
no effect inside the container. The only supported auth path is the in-container
OAuth login, which leaves teams that must route model traffic through an
internal gateway (LiteLLM, an enterprise proxy) unable to use the image (#74).

`settings.docker.json`'s `env` block is a working but undocumented alternative,
and it puts a plaintext token in a host file — strictly worse than the bare-name
env forwarding every other credential in `run.sh` uses.

Self-hosted gateways usually terminate TLS with an internal CA. Without a way to
trust it, the flag would appear to work and then fail on the first request.

## What Changes

- **Add an `--api` opt-in flag** to `run.sh`. It forwards, by bare name and
  only when set on the host (the value never enters the wrapper's argv), the
  Claude Code endpoint variables documented at
  <https://code.claude.com/docs/en/env-vars>: `ANTHROPIC_BASE_URL`,
  `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_CUSTOM_HEADERS`,
  `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`,
  `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, and the
  deprecated-but-honoured `ANTHROPIC_SMALL_FAST_MODEL`. No flag → none of them
  reach the container.
- **Private CA, reusing the `--gh` plumbing.** Under `--api`, when the host sets
  `CLAUDE_DOCKER_API_CA` to a PEM file, `run.sh` mounts it read-only at
  `/usr/local/share/ca-certificates/claude-docker-api.crt`; the entrypoint's
  existing `update-ca-certificates` step (root, before the privilege drop) now
  runs when either that file or the gh-proxy CA is present. Claude Code's native
  binary trusts the OS store by default
  (<https://code.claude.com/docs/en/network-config>), so no
  `NODE_EXTRA_CA_CERTS` override is set — and so none can collide with the one
  `--gh` sets. A set-but-missing path is a startup error, not a silent skip.
- **Statusline** gains an `api` tag.
- **Docs**: README opt-in table row, a short section documenting the
  `settings.docker.json` `env` alternative with its plaintext-on-host caveat,
  and a threat-model line (a custom endpoint receives all prompt content, i.e.
  every file the agent reads).
- **Smoke**: a bespoke `api` opt-in asserting the endpoint env arrives and the
  mounted CA lands in the system trust bundle.

Deliberately *not* in scope:

- **Bedrock / Vertex / Foundry** (`CLAUDE_CODE_USE_BEDROCK`,
  `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY` and their
  `ANTHROPIC_{BEDROCK,VERTEX,FOUNDRY}_*` variables) are **deferred to a
  follow-up**. They imply cloud credentials (for Bedrock, composing with
  `--aws`) and deserve their own design.
- **No new tmpfs mask**: nothing persists to a credential directory.
- **No live `env` entry in `examples/settings.docker.json`**: it is a
  copy-paste starter, and a placeholder base URL there would silently break
  every session of anyone who copies it. The README documents the snippet
  instead.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `external-cli-tools`: adds a requirement for the `--api` model-endpoint
  opt-in (env forwarding, default-deny, optional private CA).
- `cli-help`: `--api` joins the enumerated wrapper flags.

## Impact

- **Code**: `run.sh` (flag, case arm, help, env list, CA mount, statusline tag),
  `entrypoint.sh` (CA-install condition).
- **Tests**: `smoke/smoke.sh`, `smoke/assert-in-container.sh`, one CI cell.
- **Docs**: `README.md` (opt-in table), `docs/auth.md`, `docs/security.md`, `docs/workflows.md`, `docs/maintenance.md`.
- **No breaking changes**; purely additive.
