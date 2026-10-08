## Why

A customer needs proof that a session's prompts stay within the EU (#75). `--api` (#104) points Claude Code at an in-region gateway, but nothing enforces or records that: the container has full egress, so model traffic could still reach Anthropic's own endpoints, and there is nothing to show an auditor.

The review of #101 narrowed the requirement:

- Only **model (LLM) traffic** has to stay in the EU, not git, package installs or web fetches.
- Only **Claude Code**, not other tooling.
- The evidence is **logs from a network control**. Turning them into a report belongs with the team that needs it.
- The requirement is about the **running container**, not where the image came from.
- It must cost nothing to anyone who doesn't need it. Most gateway users don't, and an allowlist that every colleague has to maintain would not be adopted.

This change replaces three earlier drafts of #101 (`api-egress-policy`, `api-egress-model-lock`, `egress-lock-opt-in`), none of which reached `main`, with one change that describes the design as built.

## What Changes

- New wrapper flag **`--egress-lock`**. It requires `--api`; given alone, it is a startup error. Plain `--api` is unchanged.
- **The network is the boundary.** The agent container is attached only to a per-session `--internal` network, so it has no route off the host. It reaches external hosts only through a per-session squid forward-proxy sidecar (HTTPS via `CONNECT`, no TLS interception) and gets `http_proxy` / `https_proxy` in both spellings.
- **Model traffic only.** The proxy allows the `ANTHROPIC_BASE_URL` host, refuses `*.anthropic.com`, `*.claude.ai` and `*.claude.com`, and allows every other host on 80/443. Metadata, link-local and loopback destinations, ports other than 80/443, and `CONNECT` to anything but 443 are always refused.
- **Startup checks.** `ANTHROPIC_BASE_URL` must be set, its host must be a valid hostname or IPv4 address, and it must not be a provider host. All are checked before any container resource exists.
- `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` in the agent container.
- **Evidence.** At session end the EXIT trap saves the proxy's access log and a `.meta` file under `$XDG_STATE_HOME/claude-docker/egress/`, prints the denied hosts, and never rotates or deletes saved logs.
- **`--gh` composes.** The gh sidecar joins the internal network, and squid resolves the three GitHub hosts to it.
- **squid ships in the agent image** and runs as its own sidecar with `--entrypoint /usr/sbin/squid`, as `proxy`, with `--cap-drop ALL`.
- Fail-closed lifecycle mirroring the `--gh` sidecar.

## Capabilities

### New Capabilities

- `api-egress-policy`: `--egress-lock` routes all of a session's egress through a logging proxy that keeps model traffic away from the providers' own hosts.

### Modified Capabilities

- `cli-help`: documents `--egress-lock` and `XDG_STATE_HOME`.

## Non-goals

- Egress filtering in general. Every non-provider host on 80/443 stays reachable, so this is not a data-loss control (see design.md).
- A host or repo allowlist, in any form.
- An audit report. The saved `.log` / `.meta` files are the interface.
- SSH and other non-HTTP protocols (blocked under the lock; use HTTPS remotes).
- A podman CI cell. Podman is validated manually (tasks.md §6).

## Impact

- `run.sh`: flag, endpoint checks, egress networks, squid sidecar, gh-sidecar join, proxy env, EXIT trap and stale prune, saved log.
- `Dockerfile`: `squid` in the apt layer.
- Tests: `tests/test_egress_policy.py`, `tests/bats/run.bats`, `smoke/egress.sh`, `smoke/assert-in-container.sh` (`check_egress`), two CI cells in `ci.yml`.
- Docs: `docs/auth.md` (API egress lock), `docs/security.md`, `docs/maintenance.md`, `docs/usage.md`, `README.md`, `SECURITY.md`.
