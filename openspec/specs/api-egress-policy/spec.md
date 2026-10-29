# api-egress-policy Specification

## Purpose

Make the model traffic of an `--api --egress-lock` session provable. The agent container's only ways off its internal network are a per-session squid forward proxy, run from its own image, which logs every connection it carries, Claude Code's model requests included, and the auth-proxy sidecar, whose upstreams are fixed. The proxy allows the `ANTHROPIC_BASE_URL` endpoint, refuses the model providers' own hosts and leaves other hosts open, and Claude Code's managed settings keep its model traffic on that endpoint. The proxy's log is saved on the host as the session's evidence. Sessions without `--egress-lock`, including plain `--api` sessions, are unaffected.

## Requirements

### Requirement: Composes with the --gh auth-proxy sidecar

When `--egress-lock` is passed and the auth-proxy sidecar is active (for `--gh`, `--glab` or `--api`), the sidecar SHALL additionally be attached to the session's internal network, and the agent container SHALL NOT be attached to the sidecar's own network. The agent container's `--add-host` entries for the names the sidecar serves (`github.com`, `api.github.com` and `uploads.github.com` under `--gh`, the proxied GitLab host under `--glab`, `claude-docker-api-proxy` under `--api`) SHALL point at the sidecar's address on that network. The egress proxy SHALL resolve the same names to that address, and SHALL allow the sidecar's own ports for those names only: 8080 for `claude-docker-api-proxy`, and the proxied GitLab host's port when it has one. Proxied traffic thus reaches the sidecar and still carries the injected credential. `CLAUDE_DOCKER_ADD_HOSTS` entries SHALL be given to the egress proxy too, except those for names the sidecar serves.

#### Scenario: GitHub API through both sidecars

- **GIVEN** `--gh --api --egress-lock` with a host token
- **WHEN** `curl --cacert <session CA> https://api.github.com/user` runs in the agent container without an `Authorization` header
- **THEN** TLS verifies against the sidecar's session CA
- **AND** GitHub answers for the host token, not for an anonymous request, which proves the sidecar injected the credential and forwarded the request upstream

#### Scenario: Model traffic through both sidecars

- **GIVEN** `--api --egress-lock`
- **WHEN** Claude Code sends a model request to `http://claude-docker-api-proxy:8080`
- **THEN** the egress proxy forwards it to the auth-proxy sidecar on the internal network and logs it
- **AND** the sidecar forwards it to the host's `ANTHROPIC_BASE_URL` with the real credential

### Requirement: Fail-closed lifecycle

The internal network, the outbound network and the proxy sidecar SHALL be named per session (`claude-egress-<id>`, `claude-egress-out-<id>`, `claude-egress-proxy-<id>`) and removed by the EXIT trap, which SHALL be installed before any of them is created. Failure to build the proxy image, to create either network, to start the proxy, or to detect it accepting connections within 15 seconds, or the proxy exiting during startup, SHALL abort the session before the agent container starts. It SHALL never fall back to unfiltered egress. The startup prune SHALL remove stopped `claude-egress-proxy-*` containers and unused `claude-egress-*` networks.

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

Under `--egress-lock`, `run.sh` SHALL refuse an `ANTHROPIC_BASE_URL` with any character outside RFC 3986's unreserved, reserved (except `[` and `]`) and `%`. It SHALL mount Claude Code managed settings read-only at `/etc/claude-code/managed-settings.json` whose `env` sets `ANTHROPIC_BASE_URL` to the session's endpoint (under `--api`, to `http://claude-docker-api-proxy:8080`, the auth-proxy sidecar whose only upstream is that endpoint) and every `CLAUDE_CODE_USE_*` switch that selects a model backend to `0`: `CLAUDE_CODE_USE_GATEWAY`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_ANTHROPIC_AWS`, `CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD`, `CLAUDE_CODE_USE_MANTLE` and `CLAUDE_CODE_USE_VERTEX` as of Claude Code 2.1.302. The same `env` SHALL set `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY` to the session's squid and `no_proxy` and `NO_PROXY` to loopback only, so a project can't take Claude Code's model requests off the proxy. Sessions without `--egress-lock` SHALL NOT get this file. CI SHALL fail when the image's Claude Code knows a `CLAUDE_CODE_USE_*` switch that is neither pinned off nor listed as selecting no backend.

#### Scenario: A project setting doesn't move the model traffic

- **GIVEN** an `--egress-lock` session whose workspace `.claude/settings.json` sets `ANTHROPIC_BASE_URL` to another host, or switches on any backend (gateway, Bedrock, Foundry, Anthropic on AWS, Anthropic on Google Cloud, Mantle or Vertex) with a base URL of its own
- **WHEN** Claude Code sends a model request
- **THEN** the request goes to the session's endpoint, not to the project's host

#### Scenario: A Claude Code release adds a backend

- **GIVEN** a claude-code pin whose bundle knows a `CLAUDE_CODE_USE_*` switch that the managed settings don't pin off and that isn't listed as selecting no backend
- **WHEN** CI runs `tests/integration/managed-settings-precedence.sh` against the image
- **THEN** it fails and names the switch

#### Scenario: Under --api the pin is the sidecar

- **GIVEN** an `--api --egress-lock` session
- **WHEN** the agent reads `/etc/claude-code/managed-settings.json`
- **THEN** its `ANTHROPIC_BASE_URL` is `http://claude-docker-api-proxy:8080`, not the host's endpoint

#### Scenario: A project can't take the model requests off the proxy

- **GIVEN** an `--api --egress-lock` session in a project whose `.claude/settings.json` sets `NO_PROXY=claude-docker-api-proxy`, or an empty `HTTPS_PROXY`
- **WHEN** Claude Code sends a model request
- **THEN** it goes through squid to the auth-proxy sidecar, and the saved squid log lists it

#### Scenario: The agent can't change the managed settings

- **GIVEN** an `--egress-lock` session
- **WHEN** the agent tries to write `/etc/claude-code/managed-settings.json` or create a file in `/etc/claude-code`
- **THEN** both fail

#### Scenario: A URL that needs escaping is refused

- **GIVEN** `ANTHROPIC_BASE_URL` contains a `"`, a backslash, a quote or whitespace
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

### Requirement: The proxy runs from its own image

The agent image SHALL NOT contain squid. The proxy sidecar SHALL run squid from an image built from `run.sh`'s Containerfile, `FROM` a digest-pinned Alpine base with squid at least 7.6, as the `squid` user, unless `CLAUDE_DOCKER_EGRESS_PROXY_IMAGE` names another image. The image tag SHALL be derived from the Containerfile's content, and `run.sh` SHALL build it only when the engine doesn't have it. The squid config SHALL refuse the cache manager before any other rule.

#### Scenario: First use builds the image

- **GIVEN** an engine without the proxy image
- **WHEN** the user starts an `--egress-lock` session
- **THEN** `run.sh` builds the image before starting the proxy, and a failed build aborts the session before any container starts

#### Scenario: Later sessions reuse it

- **GIVEN** the engine already has the image for the current Containerfile
- **WHEN** the user starts an `--egress-lock` session
- **THEN** `run.sh` doesn't build, and the session's `.meta` names the proxy image and its ID

### Requirement: The session's egress log is saved on the host

When an `--egress-lock` session whose proxy was started exits, the EXIT trap SHALL, before removing the proxy, write the proxy's access log to `<state>/claude-docker/egress/<start>-<id>.log` and a `<start>-<id>.meta` file of `key=value` lines (`start`, `end`, `user`, `host`, `workspace`, `image`, `image_id`, `proxy_image`, `proxy_image_id`, `endpoint`), where `<state>` is `$XDG_STATE_HOME` or `~/.local/state`. That directory SHALL NOT be mounted into any container. `run.sh` SHALL NOT rotate or delete saved logs. `run.sh` SHALL check the copy: when the engine's log command fails, or the proxy had been accepting connections but the engine's output lacks squid's `Accepting HTTP Socket connections` startup line, it SHALL print that the log in that file is missing or incomplete, with the reason, and SHALL NOT report it saved. The check SHALL NOT fail the teardown.

#### Scenario: Log saved

- **WHEN** an `--egress-lock` session that connected to `example.org` exits
- **THEN** a `.log` file under the state directory contains the `CONNECT example.org:443` line
- **AND** its `.meta` file contains `endpoint=` followed by the `ANTHROPIC_BASE_URL` host
- **AND** `run.sh` reports the log saved

#### Scenario: The copy fails

- **GIVEN** an `--egress-lock` session whose engine can't return the proxy's log (for example, a log driver that doesn't support reading)
- **WHEN** the session exits
- **THEN** `run.sh` prints that the log in the `.log` file is missing or incomplete, with the engine's error
- **AND** it doesn't print "egress log saved"

#### Scenario: The log driver rotated the log

- **GIVEN** an `--egress-lock` session whose engine kept only the end of the proxy's log (`max-size` in `daemon.json`)
- **WHEN** the session exits
- **THEN** `run.sh` prints that the log in the `.log` file is incomplete because squid's startup line is gone
- **AND** it doesn't print "egress log saved"

### Requirement: The network is the boundary

A client inside the agent container that ignores proxy settings SHALL NOT reach any external address, whether it dials by name or by IP. External DNS names SHALL NOT resolve inside the agent container. The agent container's only ways off its internal network SHALL be the egress proxy, which logs every connection it carries, and, when active, the auth-proxy sidecar, which forwards only to its fixed upstreams (the GitHub hosts under `--gh`, the proxied GitLab host under `--glab`, `ANTHROPIC_BASE_URL` under `--api`). A request the agent sends straight to the auth-proxy sidecar is in the sidecar's audit log, not the egress proxy's.

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

The proxy SHALL deny destinations in `169.254.0.0/16`, `fe80::/10`, `127.0.0.0/8`, `0.0.0.0/8` and `::1`, the metadata addresses `100.100.100.200` (Alibaba Cloud) and `fd00:ec2::254` (AWS IPv6), and the hostnames `metadata.google.internal` and `metadata.azure.internal`, above every allow rule. These checks SHALL apply to the address the proxy resolves for a hostname, not just to IP-literal requests. Private ranges SHALL be reachable. The proxy SHALL permit only ports 80 and 443, and `CONNECT` only to 443, except that the `ANTHROPIC_BASE_URL` host is also reachable on the endpoint's port; that exception SHALL come after the metadata, link-local and loopback denies.

#### Scenario: Cloud metadata

- **WHEN** `curl http://169.254.169.254/` runs in the agent container
- **THEN** the proxy answers 403

#### Scenario: Other clouds' metadata addresses

- **WHEN** a request for `http://100.100.100.200/` or `http://[fd00:ec2::254]/` is sent through the proxy
- **THEN** the proxy answers 403

#### Scenario: Name resolving to loopback

- **WHEN** a request for `http://localhost/` is sent through the proxy
- **THEN** the proxy answers 403

#### Scenario: Non-443 CONNECT

- **GIVEN** `ANTHROPIC_BASE_URL=https://example.com`
- **WHEN** a request for `https://example.com:8443/` is sent through the proxy
- **THEN** the proxy answers 403

### Requirement: --egress-lock routes all network egress through the proxy

`run.sh` SHALL leave the agent container's networking unchanged unless the user passes `--egress-lock`. `--egress-lock` SHALL require `--api` or `--api-direct`: given without either, `run.sh` SHALL exit 1 before creating any container resource. `--api` or `--api-direct` without `--egress-lock` SHALL NOT create any egress network or egress proxy. Under `--egress-lock`, the agent container SHALL be attached only to a per-session network created with `--internal`, so that it has no route off the host, and SHALL reach external hosts only through a per-session forward-proxy sidecar. The agent container's capability set SHALL be the same with and without `--egress-lock`. Under `--egress-lock` the agent container SHALL receive `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.

#### Scenario: --egress-lock absent

- **WHEN** the user runs `claude-docker --api ~/repo` without `--egress-lock`
- **THEN** no `claude-egress-*` network or container is created
- **AND** the agent container receives no `HTTP_PROXY` / `HTTPS_PROXY`

#### Scenario: --egress-lock without --api

- **WHEN** the user runs `claude-docker --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-lock needs --api or --api-direct`, and no container starts

#### Scenario: --egress-lock with --api-direct

- **WHEN** the user runs `claude-docker --api-direct --egress-lock ~/repo` with `ANTHROPIC_BASE_URL` set to a gateway
- **THEN** no auth-proxy sidecar starts, and the agent container reaches the gateway itself through the egress proxy

#### Scenario: --egress-lock present

- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo` with `ANTHROPIC_BASE_URL` set to a gateway
- **THEN** the agent container is attached only to `claude-egress-<id>`, an internal network
- **AND** `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY` point at the proxy sidecar's address on that network
- **AND** `no_proxy` / `NO_PROXY` list only loopback names and addresses
- **AND** `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` is `1`
- **AND** `CapBnd` in the agent container is still `00000000000000c5`
