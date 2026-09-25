# Egress allowlist

## Why

The agent container has full outbound network access. The threat model says so
three times (`README.md` § Threat model), and five archived changes name egress
filtering as a non-goal. A prompt-injected session can send workspace contents,
the Claude OAuth token, or any opted-in credential to any host on the internet.
An in-container firewall is ruled out: it needs `NET_ADMIN`, and the capability
posture (`CapBnd=0xc5`, asserted in smoke) forbids it. The boundary has to live
outside the container (issue #75).

## What Changes

- New opt-in wrapper flag `--egress-allowlist`, plus the sticky knob
  `CLAUDE_DOCKER_EGRESS=allowlist`. Without either, nothing changes.
- Under the flag, the agent container is attached **only** to a per-session
  `--internal` network (`claude-egress-<id>`). It has no route off the host, so
  a client that ignores the proxy env vars fails closed.
- A per-session squid forward-proxy sidecar (`claude-egress-proxy-<id>`) sits
  on both that internal network and a per-session plain bridge
  (`claude-egress-out-<id>`). It enforces a default-deny host allowlist. The
  agent gets `HTTP(S)_PROXY` / `NO_PROXY` pointing at it. `CONNECT` keeps TLS
  end-to-end, so there is no CA work and no plaintext in the sidecar.
- The allowlist is assembled from four sources:
  - a built-in Anthropic base set;
  - the hosts implied by each active opt-in (`--gh`, `--gh-direct`, `--glab`,
    `--tfe`, `--aws`);
  - trusted host-side additions (`CLAUDE_DOCKER_EGRESS_ALLOW` and the
    `ANTHROPIC_BASE_URL` gateway host);
  - a per-project proposal file (`<workspace>/.claude-docker/allowed-hosts`).
    It takes effect only after host-side approval, recorded by content hash.
- Denies sit above every allow. Cloud metadata and link-local are always
  denied. Targets given as IP literals are denied for every source except
  trusted host-side entries. So are names that resolve to private, loopback or
  CGNAT addresses (DNS-rebinding defence).
- The squid binary ships in the agent image, which is already pinned and
  CVE-scanned. The sidecar is `$IMAGE` run with `--entrypoint squid`, so there
  is no new image to pin.
- When the session ends, `run.sh` prints the denied hosts and where to allow
  them.
- `--gh` composes: the auth-proxy sidecar also joins the internal network, so
  squid resolves the three intercepted hostnames to it (via its `hosts_file`),
  so the token-injection path is unchanged.
- Podman is refused under the flag for this iteration (fail closed), pending
  verification of `--internal` and multi-network semantics there.

## Capabilities

### New Capabilities

- `egress-allowlist`: Opt-in default-deny network egress for the agent
  container. Covers the internal network, the forward-proxy sidecar,
  allowlist sources and approval, unconditional denies, composition with
  `--gh`, lifecycle and fail-closed startup, and denial feedback.

### Modified Capabilities

- `cli-help`: `--egress-allowlist` and `CLAUDE_DOCKER_EGRESS` are listed in
  `--help`.

## Impact

- `run.sh` gains:
  - flag and env parsing;
  - allowlist assembly and validation, plus the approval store;
  - squid config generation;
  - network and sidecar lifecycle (trap, prune, fail-closed startup);
  - `--gh` composition;
  - agent network and proxy env;
  - an exit summary of denied hosts.
- `Dockerfile`: `squid` installed via apt (no-install-recommends).
- `smoke/assert-in-container.sh`, `smoke/smoke.sh`, `.github/workflows/ci.yml`:
  a new `run.sh`-driven egress cell. It asserts that an allowlisted host is
  reachable through the proxy. It also asserts that a non-allowlisted host,
  the metadata IP, a raw non-proxy client and external DNS are all blocked.
  Finally, it checks that an unapproved project list is ignored and an
  approved one is honoured.
- `README.md`: new "Egress allowlist" section, flag tables updated, threat
  model corrected.
- Known regressions under the flag (documented, by design):
  - `git+ssh` remotes stop working (HTTPS only).
  - Runtime code fetch (npm, PyPI, Go proxy, HashiCorp releases) must be
    allowlisted explicitly.
- Overlap with open PRs:
  - #87 (`--api`): its gateway host is handled here through
    `ANTHROPIC_BASE_URL`.
  - #89 and #90 (`--az`) touch the same `run.sh` regions. Once `--az` lands,
    its hosts need adding to the opt-in host table.
