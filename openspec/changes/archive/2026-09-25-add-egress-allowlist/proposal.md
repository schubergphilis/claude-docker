## Why

The agent container has unrestricted outbound network access. It lands on the
default bridge with full NAT egress, and the threat model says so: "assume
exfiltration already happened". Nothing in the container can fix that, because
an in-container firewall needs `NET_ADMIN` and the capability posture (asserted
by smoke: `CapBnd=0xc5`) forbids it. The boundary has to live outside the
container, in the network namespace (issue #75).

## What Changes

- New opt-in wrapper flag `--egress-allowlist`. Without it nothing changes.
- Under the flag, the agent container joins only a per-session **`--internal`**
  network. It has no route off the host, so any client that ignores proxy
  settings (raw sockets, direct IPs, DNS lookups) fails closed.
- A per-session **squid forward-proxy sidecar** bridges the internal network to
  a normal one and enforces a hostname allowlist (`CONNECT` for HTTPS, so TLS
  stays end-to-end and the proxy never sees plaintext or tokens). The agent
  gets `HTTP(S)_PROXY` / `NO_PROXY`.
- Squid runs from the **agent image itself** (installed from the Ubuntu archive
  in the Dockerfile). No new image, no new pin.
- The allowlist is the union of:
  - a built-in base set (the Anthropic API and Claude login hosts);
  - under `--api` (#87), the host of `ANTHROPIC_BASE_URL` when it is set on
    the host;
  - hosts implied by each credential opt-in that is passed (`--gh`,
    `--gh-direct`, `--glab`, `--tfe`, `--aws`, `--az`);
  - host-side entries in `CLAUDE_DOCKER_EGRESS_ALLOW` (hostnames, `.suffix`
    domains, IPv4 addresses or CIDRs), strictly validated.
- Denies that sit above the allowlist: link-local and cloud metadata
  (`169.254.0.0/16`, `fe80::/10`, `metadata.google.internal`,
  `metadata.azure.internal`), loopback, and private ranges (RFC1918, CGNAT,
  ULA) **by resolved address**, so an allowlisted name that resolves inward is
  refused. Only an explicit IPv4/CIDR entry re-opens a private range. Only
  ports 80 and 443, and `CONNECT` only to 443.
- `--gh` composes: the auth-proxy sidecar joins the internal network too, and
  squid resolves the three intercepted GitHub hostnames to it.
- Fail-closed startup (a network or proxy that does not come up aborts the
  session), trap-before-create teardown, stale-resource prune, and an
  end-of-session summary naming every denied host and the knob to allow it.
- Docs: the threat model, `--ro`, and `--registry` text that assumes open
  egress now name the opt-in.

## Capabilities

### New Capabilities

- `egress-allowlist`: opt-in default-deny network egress through a
  per-session internal network and forward-proxy sidecar.

### Modified Capabilities

- `cli-help`: the help text documents `--egress-allowlist` and
  `CLAUDE_DOCKER_EGRESS_ALLOW`.

## Non-goals (this change)

- **Default-on.** Opt-in first. Turning it on by default is a separate
  decision, after the base host set has been confirmed against real sessions.
- **A repo-supplied allowlist** (`.claude-docker/allowed-hosts` with host-side
  approval by content hash). The file would live inside the untrusted repo, so
  it needs its own approval design. This iteration takes host-side input only,
  so no repo-controlled byte reaches the proxy config.
- `git+ssh`, and any other non-HTTP protocol. HTTPS remotes only.
- Podman parity is not verified in CI.

## Impact

- `run.sh`: flag, allowlist assembly and validation, squid config generator,
  network and sidecar lifecycle, `--gh` composition, help text.
- `Dockerfile`: `squid` from the Ubuntu archive.
- `smoke/egress.sh` (new, `run.sh`-driven), `smoke/assert-in-container.sh`
  (`check_egress`), `.github/workflows/ci.yml` (two cells).
- `docs/security.md`: new section, threat-model corrections; `README.md`: flag table row.
