## Why

A customer needs proof that traffic from a session stays within the EU (#75). `--api` (#104) sends model traffic to an in-region gateway, but the container still has full egress: Anthropic's own endpoints, telemetry, registries, and any IP typed into `curl` are all reachable, and there is nothing to show an auditor. The boundary has to be enforced by the network and be checkable, and it must cost nothing to users who don't need it.

## What Changes

- **`--api` blocks all network egress.** The agent container joins a per-session `--internal` network with no route off the host. It reaches external hosts only through a per-session squid forward-proxy sidecar (HTTPS via `CONNECT`, no TLS interception). Sessions without `--api` are unchanged.
- **One host-side policy file is the whole allowlist.** `CLAUDE_DOCKER_EGRESS_POLICY` points at `egress-policy.yaml`: a strict YAML subset with one `allow:` key and `- host` / `- .suffix` / `- IPv4/CIDR` items. Nothing is implied: no Anthropic base set, no `ANTHROPIC_BASE_URL` host, no hosts from other opt-ins. The file is parsed line by line, and every entry is validated. Any other line or an invalid entry aborts startup with `file:line`. Nothing in a workspace contributes.
- **Fail fast on the model endpoint.** If the host of `ANTHROPIC_BASE_URL` (default `api.anthropic.com`) isn't covered by the policy, `run.sh` aborts before any container resource exists and names the host and the file.
- **Denies above the policy.** Metadata, link-local and loopback are always denied. Private ranges are denied by *resolved* address unless a CIDR entry covers them. Only ports 80/443 are allowed, and `CONNECT` only to 443. Unlisted names are refused without being resolved.
- **Squid ships in the agent image** (Ubuntu archive) and runs as its own sidecar with `--entrypoint /usr/sbin/squid`, as `proxy`, `--cap-drop ALL`. There is no new image or pin, and the agent's `CapBnd` stays `0xc5`.
- **`--gh` composes.** The gh sidecar joins the internal network, and squid resolves the three GitHub API hosts to it. The GitHub hosts must be in the policy like any other.
- Fail-closed lifecycle mirroring `--gh`. An end-of-session summary names the denied hosts and the policy file.

## Capabilities

### New Capabilities

- `api-egress-policy`: deny-all egress for `--api` sessions, opened only by the host-side policy file.

### Modified Capabilities

- `cli-help`: `--api` help describes the lock; `CLAUDE_DOCKER_EGRESS_POLICY` is documented.

## Non-goals (this change)

- Egress filtering for sessions without `--api`.
- A repo-supplied allowlist, in any form.
- SSH and other non-HTTP protocols (blocked under `--api`; use HTTPS remotes).
- IPv6 entries in the policy.
- A podman CI cell.

## Impact

- `run.sh`: policy parser and validator, the model-endpoint check, the networks, the squid sidecar, the trap, the prune, and `--gh` composition.
- `Dockerfile`: `squid` in the apt layer.
- `smoke/egress.sh` (new), `smoke/assert-in-container.sh` (`check_egress`), `tests/test_egress_policy.py` (new, docker-free), and `ci.yml` (two cells).
- `README.md` (API egress lock section, threat model, `--api` row), `SECURITY.md` (scope).
- **Breaking for `--api`**: an `--api` session needs a policy file. `--api` is unreleased (#104).
