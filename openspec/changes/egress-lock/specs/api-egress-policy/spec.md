## ADDED Requirements

### Requirement: Composes with the --gh auth-proxy sidecar

When `--egress-lock` is passed and the `--gh` sidecar is active, the gh sidecar SHALL additionally be attached to the session's internal network. The agent container's `--add-host` entries for `github.com`, `api.github.com` and `uploads.github.com` SHALL point at the gh sidecar's address on that network. The egress proxy SHALL resolve the same three hostnames to that address, so that proxied GitHub traffic reaches the gh sidecar and still carries the injected credential.

#### Scenario: GitHub API through both sidecars

- **GIVEN** `--gh --api --egress-lock` with a host token
- **WHEN** `curl --cacert <session CA> https://api.github.com/user` runs in the agent container without an `Authorization` header
- **THEN** TLS verifies against the gh sidecar's session CA
- **AND** GitHub answers for the host token, not for an anonymous request, which proves the gh sidecar injected the credential and forwarded the request upstream

### Requirement: Fail-closed lifecycle

The internal network, the outbound network and the proxy sidecar SHALL be named per session (`claude-egress-<id>`, `claude-egress-out-<id>`, `claude-egress-proxy-<id>`) and removed by the EXIT trap, which SHALL be installed before any of them is created. Failure to create either network, to start the proxy, or to detect it accepting connections within 15 seconds, or the proxy exiting during startup, SHALL abort the session before the agent container starts. It SHALL never fall back to unfiltered egress. The startup prune SHALL remove stopped `claude-egress-proxy-*` containers and unused `claude-egress-*` networks.

#### Scenario: Proxy fails to start

- **WHEN** the proxy sidecar exits during startup
- **THEN** `run.sh` exits non-zero, prints the proxy's last log lines, and never starts the agent container

#### Scenario: Teardown

- **WHEN** an `--egress-lock` session exits
- **THEN** no `claude-egress-*` container or network from that session remains

### Requirement: Denied hosts are reported to the user

`run.sh` SHALL print the proxy sidecar's name, the model endpoint and the log directory to stderr at startup. When the session ends, it SHALL print every distinct host the proxy denied during the session after `egress proxy blocked:`, with its port unless that is 443 or 80, and the path of the saved log.

#### Scenario: End-of-session summary

- **GIVEN** a session in which `api.anthropic.com` was denied
- **WHEN** the session exits
- **THEN** stderr contains `egress proxy blocked:` followed by a list that includes `api.anthropic.com`
- **AND** stderr names the saved log file

#### Scenario: A denied non-default port is kept in the summary

- **GIVEN** a session in which `CONNECT example.com:8443` was denied
- **WHEN** the session exits
- **THEN** the `egress proxy blocked:` list contains `example.com:8443`, not a bare `example.com`

### Requirement: Model traffic reaches only the configured endpoint

Under `--egress-lock`, `run.sh` SHALL exit 1 before creating any container resource when `ANTHROPIC_BASE_URL` is unset or empty, when its host is not a hostname or IPv4 address of at most 253 characters made of letters, digits, `-` and `.`, when its port is not a number from 1 to 65535, or when its host, compared case-insensitively, is `anthropic.com`, `claude.ai` or `claude.com` or a subdomain of one. The endpoint's port is the one in `ANTHROPIC_BASE_URL`, or the scheme's default (80 for `http`, 443 otherwise). The proxy SHALL allow the `ANTHROPIC_BASE_URL` host on the endpoint's port, and on 80/443, then deny `.anthropic.com`, `.claude.ai` and `.claude.com`, then allow every other destination that the metadata, loopback and port rules permit. HTTPS SHALL be proxied by `CONNECT` without TLS interception.

#### Scenario: No endpoint

- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo` with a token but no `ANTHROPIC_BASE_URL`
- **THEN** `run.sh` exits 1 with `--egress-lock needs ANTHROPIC_BASE_URL`, and no container starts

#### Scenario: Endpoint is a provider host

- **GIVEN** `ANTHROPIC_BASE_URL=https://api.anthropic.com`
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

#### Scenario: Endpoint is a provider host in another case

- **GIVEN** `ANTHROPIC_BASE_URL=https://Api.Anthropic.com`
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

#### Scenario: Endpoint on a non-default port

- **GIVEN** an `--egress-lock` session with `ANTHROPIC_BASE_URL=https://gw.example.eu:8443`
- **WHEN** the agent requests `https://gw.example.eu:8443/` and `https://example.org:8443/` through the proxy
- **THEN** the proxy allows the `CONNECT gw.example.eu:8443` and answers `CONNECT example.org:8443` with 403

#### Scenario: Invalid endpoint port

- **GIVEN** `ANTHROPIC_BASE_URL=https://gw.example.eu:65536`
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 with `is not a port number`

#### Scenario: Endpoint smuggles squid config

- **GIVEN** an `ANTHROPIC_BASE_URL` whose host contains a newline or a space
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 with `is not a valid hostname`

#### Scenario: Provider host refused, other hosts open

- **GIVEN** an `--egress-lock` session with `ANTHROPIC_BASE_URL=https://example.com`
- **WHEN** the agent requests `https://example.com/`, `https://example.org/` and `https://api.anthropic.com/` through the proxy
- **THEN** the first two succeed and the proxy answers `CONNECT api.anthropic.com` with 403

### Requirement: Claude Code's endpoint can't be moved by the workspace

Under `--egress-lock`, `run.sh` SHALL refuse an `ANTHROPIC_BASE_URL` with any character outside RFC 3986's unreserved, reserved (except `[` and `]`) and `%`. It SHALL mount Claude Code managed settings read-only at `/etc/claude-code/managed-settings.json` whose `env` sets `ANTHROPIC_BASE_URL` to the session's endpoint and `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` and `CLAUDE_CODE_USE_FOUNDRY` to `0`. Sessions without `--egress-lock` SHALL NOT get this file.

#### Scenario: A project setting doesn't move the model traffic

- **GIVEN** an `--egress-lock` session whose workspace `.claude/settings.json` sets `ANTHROPIC_BASE_URL` to another host, or switches on Bedrock, Vertex or Foundry with a base URL of its own
- **WHEN** Claude Code sends a model request
- **THEN** the request goes to the session's endpoint, not to the project's host

#### Scenario: The agent can't change the managed settings

- **GIVEN** an `--egress-lock` session
- **WHEN** the agent tries to write `/etc/claude-code/managed-settings.json` or create a file in `/etc/claude-code`
- **THEN** both fail

#### Scenario: A URL that needs escaping is refused

- **GIVEN** `ANTHROPIC_BASE_URL` contains a `"`, a backslash, a quote or whitespace
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

### Requirement: The session's egress log is saved on the host

When an `--egress-lock` session whose proxy was started exits, the EXIT trap SHALL, before removing the proxy, write the proxy's access log to `<state>/claude-docker/egress/<start>-<id>.log` and a `<start>-<id>.meta` file of `key=value` lines (`start`, `end`, `user`, `host`, `workspace`, `image`, `image_id`, `endpoint`), where `<state>` is `$XDG_STATE_HOME` or `~/.local/state`. That directory SHALL NOT be mounted into any container. `run.sh` SHALL NOT rotate or delete saved logs.

#### Scenario: Log saved

- **WHEN** an `--egress-lock` session that connected to `example.org` exits
- **THEN** a `.log` file under the state directory contains the `CONNECT example.org:443` line
- **AND** its `.meta` file contains `endpoint=` followed by the `ANTHROPIC_BASE_URL` host

### Requirement: The network is the boundary, so the proxy log is complete

A client inside the agent container that ignores proxy settings SHALL NOT reach any external address, whether it dials by name or by IP. External DNS names SHALL NOT resolve inside the agent container. This makes the proxy's access log a complete record of the session's connections.

#### Scenario: Proxy-unaware client to a reachable host

- **WHEN** `curl --noproxy '*' https://example.org/` runs in the agent container
- **THEN** it fails

#### Scenario: Direct IP connection

- **WHEN** `curl --noproxy '*' http://1.1.1.1/` runs in the agent container
- **THEN** it fails

#### Scenario: External DNS

- **WHEN** `getent hosts example.org` runs in the agent container
- **THEN** it returns no address

### Requirement: Metadata and loopback destinations are denied by resolved address

The proxy SHALL deny destinations in `169.254.0.0/16`, `fe80::/10`, `127.0.0.0/8`, `0.0.0.0/8` and `::1`, and the hostnames `metadata.google.internal` and `metadata.azure.internal`, above every allow rule. These checks SHALL apply to the address the proxy resolves for a hostname, not just to IP-literal requests. Private ranges SHALL be reachable. The proxy SHALL permit only ports 80 and 443, and `CONNECT` only to 443, except that the `ANTHROPIC_BASE_URL` host is also reachable on the endpoint's port; that exception SHALL come after the metadata, link-local and loopback denies.

#### Scenario: Cloud metadata

- **WHEN** `curl http://169.254.169.254/` runs in the agent container
- **THEN** the proxy answers 403

#### Scenario: Name resolving to loopback

- **WHEN** a request for `http://localhost/` is sent through the proxy
- **THEN** the proxy answers 403

#### Scenario: Non-443 CONNECT

- **GIVEN** `ANTHROPIC_BASE_URL=https://example.com`
- **WHEN** a request for `https://example.com:8443/` is sent through the proxy
- **THEN** the proxy answers 403

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
