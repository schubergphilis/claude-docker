## MODIFIED Requirements

### Requirement: --api blocks all network egress

`run.sh` SHALL leave the agent container's networking unchanged unless the user passes `--api`. Under `--api`, the agent container SHALL be attached only to a per-session network created with `--internal`, so that it has no route off the host, and SHALL reach external hosts only through a per-session forward-proxy sidecar. No other flag SHALL turn this on or off. The agent container's capability set SHALL be the same with and without `--api`. Under `--api` the agent container SHALL receive `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.

#### Scenario: --api absent

- **WHEN** the user runs `claude-docker ~/repo` without `--api`
- **THEN** no `claude-egress-*` network or container is created
- **AND** the agent container receives no `HTTP_PROXY` / `HTTPS_PROXY`

#### Scenario: --api present

- **WHEN** the user runs `claude-docker --api ~/repo` with `ANTHROPIC_BASE_URL` set to a gateway
- **THEN** the agent container is attached only to `claude-egress-<id>`, an internal network
- **AND** `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY` point at the proxy sidecar's address on that network
- **AND** `no_proxy` / `NO_PROXY` list only loopback names and addresses
- **AND** `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is `1`
- **AND** `CapBnd` in the agent container is still `00000000000000c5`

### Requirement: Composes with the --gh auth-proxy sidecar

When `--api` is passed and the `--gh` sidecar is active, the gh sidecar SHALL additionally be attached to the session's internal network. The agent container's `--add-host` entries for `github.com`, `api.github.com` and `uploads.github.com` SHALL point at the gh sidecar's address on that network. The egress proxy SHALL resolve the same three hostnames to that address, so that proxied GitHub traffic reaches the gh sidecar and still carries the injected credential.

#### Scenario: GitHub API through both sidecars

- **GIVEN** `--gh --api` with a host token
- **WHEN** `curl --cacert <session CA> https://api.github.com/zen` runs in the agent container
- **THEN** TLS verifies against the gh sidecar's session CA
- **AND** GitHub's response reaches the client, which proves the gh sidecar forwarded the request upstream

### Requirement: Denied hosts are reported to the user

`run.sh` SHALL print the proxy sidecar's name, the model endpoint and the log directory to stderr at startup. When the session ends, it SHALL print every distinct host the proxy denied during the session after `egress proxy blocked:`, and the path of the saved log.

#### Scenario: End-of-session summary

- **GIVEN** a session in which `api.anthropic.com` was denied
- **WHEN** the session exits
- **THEN** stderr contains `egress proxy blocked:` followed by a list that includes `api.anthropic.com`
- **AND** stderr names the saved log file

## REMOVED Requirements

### Requirement: The network, not the proxy, is the boundary

**Reason**: Replaced by "The network is the boundary, so the proxy log is complete", which drops the allowlist wording.
**Migration**: None.

### Requirement: Metadata, loopback and private destinations are denied by resolved address

**Reason**: Replaced by "Metadata and loopback destinations are denied by resolved address". Private ranges are reachable, as without `--api`, and unlisted names are no longer a concept.
**Migration**: None.

### Requirement: The host-side policy file is the only allowlist

**Reason**: Only model traffic has to stay in the EU; a list of every host a session may reach costs each user configuration effort and hurts adoption.
**Migration**: None needed; `--api` and the policy file are unreleased. Unset `CLAUDE_DOCKER_EGRESS_POLICY`.

### Requirement: The model endpoint must be in the policy

**Reason**: There is no policy file. The endpoint is always allowed, and replaced by "Model traffic reaches only the configured endpoint".
**Migration**: Set `ANTHROPIC_BASE_URL`.

## ADDED Requirements

### Requirement: Model traffic reaches only the configured endpoint

Under `--api`, `run.sh` SHALL exit 1 before creating any container resource when `ANTHROPIC_BASE_URL` is unset or empty, when its host is not a hostname or IPv4 address of at most 253 characters made of letters, digits, `-` and `.`, or when its host is `anthropic.com`, `claude.ai` or `claude.com` or a subdomain of one. The proxy SHALL allow the `ANTHROPIC_BASE_URL` host, then deny `.anthropic.com`, `.claude.ai` and `.claude.com`, then allow every other destination that the metadata, loopback and port rules permit. HTTPS SHALL be proxied by `CONNECT` without TLS interception.

#### Scenario: No endpoint

- **WHEN** the user runs `claude-docker --api ~/repo` with a token but no `ANTHROPIC_BASE_URL`
- **THEN** `run.sh` exits 1 with `--api needs ANTHROPIC_BASE_URL`, and no container starts

#### Scenario: Endpoint is a provider host

- **GIVEN** `ANTHROPIC_BASE_URL=https://api.anthropic.com`
- **WHEN** the user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

#### Scenario: Endpoint smuggles squid config

- **GIVEN** an `ANTHROPIC_BASE_URL` whose host contains a newline or a space
- **WHEN** the user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits 1 with `is not a valid hostname`

#### Scenario: Provider host refused, other hosts open

- **GIVEN** an `--api` session with `ANTHROPIC_BASE_URL=https://example.com`
- **WHEN** the agent requests `https://example.com/`, `https://example.org/` and `https://api.anthropic.com/` through the proxy
- **THEN** the first two succeed and the proxy answers `CONNECT api.anthropic.com` with 403

### Requirement: The session's egress log is saved on the host

When an `--api` session whose proxy was started exits, the EXIT trap SHALL, before removing the proxy, write the proxy's access log to `<state>/claude-docker/egress/<start>-<id>.log` and a `<start>-<id>.meta` file of `key=value` lines (`start`, `end`, `user`, `host`, `workspace`, `image`, `image_id`, `endpoint`), where `<state>` is `$XDG_STATE_HOME` or `~/.local/state`. That directory SHALL NOT be mounted into any container.

#### Scenario: Log saved

- **WHEN** an `--api` session that connected to `example.org` exits
- **THEN** a `.log` file under the state directory contains the `CONNECT example.org:443` line
- **AND** its `.meta` file contains `endpoint=` followed by the `ANTHROPIC_BASE_URL` host

### Requirement: --report builds an audit PDF

`claude-docker --report[=FILE]` SHALL, without starting any container, write a PDF (default `egress-report.pdf`) covering every saved session log. For each session it SHALL list the meta values, the log's SHA-256, every request to the endpoint or a provider host (host, squid result, count, time range, upstream IP), and the other hosts as out-of-scope traffic. A session's verdict SHALL be FAIL when any request to a provider host has a result other than `TCP_DENIED`, and `--report` SHALL then exit 1. With no saved logs it SHALL exit 1 with an error. It SHALL need only `python3` from the host, with no third-party package.

#### Scenario: Passing session

- **GIVEN** a saved log with a tunnel to the endpoint, a denied `api.anthropic.com` and a tunnel to `github.com`
- **WHEN** the user runs `claude-docker --report=r.pdf`
- **THEN** `r.pdf` is a PDF that says `Overall: PASS`, and the exit status is 0

#### Scenario: Provider request not refused

- **GIVEN** a saved log with a `TCP_TUNNEL/200` to `statsig.anthropic.com`
- **WHEN** the user runs `claude-docker --report=r.pdf`
- **THEN** `r.pdf` says `Overall: FAIL`, and the exit status is 1

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

The proxy SHALL deny destinations in `169.254.0.0/16`, `fe80::/10`, `127.0.0.0/8`, `0.0.0.0/8` and `::1`, and the hostnames `metadata.google.internal` and `metadata.azure.internal`, above every allow rule. These checks SHALL apply to the address the proxy resolves for a hostname, not just to IP-literal requests. Private ranges SHALL be reachable. The proxy SHALL permit only ports 80 and 443, and `CONNECT` only to 443.

#### Scenario: Cloud metadata

- **WHEN** `curl http://169.254.169.254/` runs in the agent container
- **THEN** the proxy answers 403

#### Scenario: Name resolving to loopback

- **WHEN** a request for `http://localhost/` is sent through the proxy
- **THEN** the proxy answers 403

#### Scenario: Non-443 CONNECT

- **WHEN** a request for `https://example.com:8443/` is sent through the proxy
- **THEN** the proxy answers 403
