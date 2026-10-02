## ADDED Requirements

### Requirement: --egress-lock routes all network egress through the proxy

`run.sh` SHALL leave the agent container's networking unchanged unless the user passes `--egress-lock`. `--egress-lock` SHALL require `--api`: given without it, `run.sh` SHALL exit 1 before creating any container resource. `--api` without `--egress-lock` SHALL NOT create any egress network or sidecar. Under `--egress-lock`, the agent container SHALL be attached only to a per-session network created with `--internal`, so that it has no route off the host, and SHALL reach external hosts only through a per-session forward-proxy sidecar. The agent container's capability set SHALL be the same with and without `--egress-lock`. Under `--egress-lock` the agent container SHALL receive `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.

#### Scenario: --egress-lock absent

- **WHEN** the user runs `claude-docker --api ~/repo` without `--egress-lock`
- **THEN** no `claude-egress-*` network or container is created
- **AND** the agent container receives no `HTTP_PROXY` / `HTTPS_PROXY`

#### Scenario: --egress-lock without --api

- **WHEN** the user runs `claude-docker --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-lock needs --api`, and no container starts

#### Scenario: --egress-lock present

- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo` with `ANTHROPIC_BASE_URL` set to a gateway
- **THEN** the agent container is attached only to `claude-egress-<id>`, an internal network
- **AND** `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY` point at the proxy sidecar's address on that network
- **AND** `no_proxy` / `NO_PROXY` list only loopback names and addresses
- **AND** `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is `1`
- **AND** `CapBnd` in the agent container is still `00000000000000c5`

## MODIFIED Requirements

### Requirement: Composes with the --gh auth-proxy sidecar

When `--egress-lock` is passed and the `--gh` sidecar is active, the gh sidecar SHALL additionally be attached to the session's internal network. The agent container's `--add-host` entries for `github.com`, `api.github.com` and `uploads.github.com` SHALL point at the gh sidecar's address on that network. The egress proxy SHALL resolve the same three hostnames to that address, so that proxied GitHub traffic reaches the gh sidecar and still carries the injected credential.

#### Scenario: GitHub API through both sidecars

- **GIVEN** `--gh --api --egress-lock` with a host token
- **WHEN** `curl --cacert <session CA> https://api.github.com/zen` runs in the agent container
- **THEN** TLS verifies against the gh sidecar's session CA
- **AND** GitHub's response reaches the client, which proves the gh sidecar forwarded the request upstream

### Requirement: Fail-closed lifecycle

The internal network, the outbound network and the proxy sidecar SHALL be named per session (`claude-egress-<id>`, `claude-egress-out-<id>`, `claude-egress-proxy-<id>`) and removed by the EXIT trap, which SHALL be installed before any of them is created. Failure to create either network, to start the proxy, or to detect it accepting connections within 15 seconds, or the proxy exiting during startup, SHALL abort the session before the agent container starts. It SHALL never fall back to unfiltered egress. The startup prune SHALL remove stopped `claude-egress-proxy-*` containers and unused `claude-egress-*` networks.

#### Scenario: Proxy fails to start

- **WHEN** the proxy sidecar exits during startup
- **THEN** `run.sh` exits non-zero, prints the proxy's last log lines, and never starts the agent container

#### Scenario: Teardown

- **WHEN** an `--egress-lock` session exits
- **THEN** no `claude-egress-*` container or network from that session remains

### Requirement: Model traffic reaches only the configured endpoint

Under `--egress-lock`, `run.sh` SHALL exit 1 before creating any container resource when `ANTHROPIC_BASE_URL` is unset or empty, when its host is not a hostname or IPv4 address of at most 253 characters made of letters, digits, `-` and `.`, or when its host is `anthropic.com`, `claude.ai` or `claude.com` or a subdomain of one. The proxy SHALL allow the `ANTHROPIC_BASE_URL` host, then deny `.anthropic.com`, `.claude.ai` and `.claude.com`, then allow every other destination that the metadata, loopback and port rules permit. HTTPS SHALL be proxied by `CONNECT` without TLS interception.

#### Scenario: No endpoint

- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo` with a token but no `ANTHROPIC_BASE_URL`
- **THEN** `run.sh` exits 1 with `--egress-lock needs ANTHROPIC_BASE_URL`, and no container starts

#### Scenario: Endpoint is a provider host

- **GIVEN** `ANTHROPIC_BASE_URL=https://api.anthropic.com`
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

#### Scenario: Endpoint smuggles squid config

- **GIVEN** an `ANTHROPIC_BASE_URL` whose host contains a newline or a space
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 with `is not a valid hostname`

#### Scenario: Provider host refused, other hosts open

- **GIVEN** an `--egress-lock` session with `ANTHROPIC_BASE_URL=https://example.com`
- **WHEN** the agent requests `https://example.com/`, `https://example.org/` and `https://api.anthropic.com/` through the proxy
- **THEN** the first two succeed and the proxy answers `CONNECT api.anthropic.com` with 403

### Requirement: The session's egress log is saved on the host

When an `--egress-lock` session whose proxy was started exits, the EXIT trap SHALL, before removing the proxy, write the proxy's access log to `<state>/claude-docker/egress/<start>-<id>.log` and a `<start>-<id>.meta` file of `key=value` lines (`start`, `end`, `user`, `host`, `workspace`, `image`, `image_id`, `endpoint`), where `<state>` is `$XDG_STATE_HOME` or `~/.local/state`. That directory SHALL NOT be mounted into any container. `run.sh` SHALL NOT rotate or delete saved logs.

#### Scenario: Log saved

- **WHEN** an `--egress-lock` session that connected to `example.org` exits
- **THEN** a `.log` file under the state directory contains the `CONNECT example.org:443` line
- **AND** its `.meta` file contains `endpoint=` followed by the `ANTHROPIC_BASE_URL` host

## REMOVED Requirements

### Requirement: --api blocks all network egress

**Reason**: The lock moves to its own opt-in, `--egress-lock` (review of #101).
**Migration**: Pass `--api --egress-lock` for the previous `--api` behaviour.

### Requirement: --report builds an audit PDF

**Reason**: Reporting for one audit, with a PDF writer and a host `python3` dependency; it belongs with the team that needs it (review of #101).
**Migration**: The saved `.log` (squid's default access-log format) and `.meta` files are unchanged; build the report from them outside claude-docker.
