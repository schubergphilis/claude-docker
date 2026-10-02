## ADDED Requirements

### Requirement: --api blocks all network egress

`run.sh` SHALL leave the agent container's networking unchanged unless the user passes `--api`. Under `--api`, the agent container SHALL be attached only to a per-session network created with `--internal`, so that it has no route off the host, and SHALL reach external hosts only through a per-session forward-proxy sidecar. No other flag SHALL turn this on or off. The agent container's capability set SHALL be the same with and without `--api`.

#### Scenario: --api absent

- **WHEN** the user runs `claude-docker ~/repo` without `--api`
- **THEN** no `claude-egress-*` network or container is created
- **AND** the agent container receives no `HTTP_PROXY` / `HTTPS_PROXY`

#### Scenario: --api present

- **WHEN** the user runs `claude-docker --api ~/repo` with a policy that covers the model endpoint
- **THEN** the agent container is attached only to `claude-egress-<id>`, an internal network
- **AND** `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY` point at the proxy sidecar's address on that network
- **AND** `no_proxy` / `NO_PROXY` list only loopback names and addresses
- **AND** `CapBnd` in the agent container is still `00000000000000c5`

### Requirement: The network, not the proxy, is the boundary

A client inside the agent container that ignores proxy settings SHALL NOT reach any external address, whether it dials by name or by IP. External DNS names SHALL NOT resolve inside the agent container.

#### Scenario: Proxy-unaware client to an allowlisted host

- **GIVEN** `example.com` is in the policy
- **WHEN** `curl --noproxy '*' https://example.com/` runs in the agent container
- **THEN** it fails

#### Scenario: Direct IP connection

- **WHEN** `curl --noproxy '*' http://1.1.1.1/` runs in the agent container
- **THEN** it fails

#### Scenario: External DNS

- **WHEN** `getent hosts example.org` runs in the agent container
- **THEN** it returns no address

### Requirement: The host-side policy file is the only allowlist

The proxy SHALL allow a request only if its destination hostname is in the policy file named by `CLAUDE_DOCKER_EGRESS_POLICY`, or its destination address is covered by an IPv4 address or CIDR in that file. HTTPS SHALL be proxied by `CONNECT` without TLS interception. No host SHALL be allowed implicitly: not the Anthropic API, not the host of `ANTHROPIC_BASE_URL`, and not the hosts of any other opt-in. No file inside a workspace SHALL contribute to the allowlist.

The policy file SHALL be read line by line, and nothing in it SHALL be evaluated. The accepted lines are:

- blank lines and `#` comments;
- exactly one top-level `allow:` key, optionally followed by a ` #` comment;
- after `allow:`, items of the form `<spaces>- <entry>`, optionally followed by a ` #` comment.

A trailing carriage return SHALL be ignored. Any other line SHALL abort startup with an error that names the file and line number.

Each entry SHALL be one of:

- a hostname, matching exactly;
- a hostname with a leading `.`, matching the domain and all of its subdomains;
- an IPv4 address or CIDR.

`run.sh` SHALL validate every entry before writing it to the proxy configuration. A hostname SHALL match `^\.?([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$` and be at most 253 characters. An address SHALL match `^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$`. An invalid entry SHALL abort startup with an error that names it and its line.

An unset `CLAUDE_DOCKER_EGRESS_POLICY` SHALL mean an empty allowlist. A set value that does not name a readable file SHALL abort startup.

All of these checks SHALL run before any container resource is created.

#### Scenario: Listed host reachable

- **GIVEN** the policy lists `example.com`
- **WHEN** `curl https://example.com/` runs in the agent container
- **THEN** it returns HTTP 200 through the proxy

#### Scenario: Unlisted host refused

- **WHEN** `curl https://example.org/` runs in the agent container
- **THEN** the proxy answers the `CONNECT` with 403

#### Scenario: Anthropic API not implied

- **GIVEN** the policy does not list `api.anthropic.com`
- **WHEN** `curl https://api.anthropic.com/` runs in the agent container
- **THEN** the proxy answers the `CONNECT` with 403

#### Scenario: Injection attempt rejected

- **GIVEN** a policy line `  - example.com http_access allow all`
- **WHEN** the user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits non-zero naming the file and line, before any container starts

#### Scenario: Unsupported YAML rejected

- **GIVEN** a policy that uses another key, flow syntax (`allow: [a.com]`), tab indentation, or a `---` marker
- **WHEN** the user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits non-zero naming the file and line, before any container starts

### Requirement: The model endpoint must be in the policy

Under `--api`, `run.sh` SHALL determine the model endpoint host: the host of `ANTHROPIC_BASE_URL` when it is set on the host, and `api.anthropic.com` otherwise. When that host is a hostname that neither an exact entry nor a `.suffix` entry in the policy covers, `run.sh` SHALL exit with status 1 before creating any container resource. The error SHALL name the host and `CLAUDE_DOCKER_EGRESS_POLICY`. This check SHALL NOT add the host to the allowlist.

#### Scenario: No policy

- **GIVEN** `ANTHROPIC_BASE_URL=https://llm.example.eu` and `CLAUDE_DOCKER_EGRESS_POLICY` unset
- **WHEN** the user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits 1 naming `llm.example.eu`, and no container starts

#### Scenario: Suffix entry covers the endpoint

- **GIVEN** `ANTHROPIC_BASE_URL=https://llm.example.eu` and a policy listing `.example.eu`
- **WHEN** the user runs `claude-docker --api ~/repo`
- **THEN** the endpoint check passes

### Requirement: Metadata, loopback and private destinations are denied by resolved address

The proxy SHALL deny, regardless of the policy, destinations in `169.254.0.0/16`, `fe80::/10`, `127.0.0.0/8`, `0.0.0.0/8` and `::1`, and the hostnames `metadata.google.internal` and `metadata.azure.internal`. It SHALL deny destinations in `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10` and `fc00::/7`, unless an allowlisted IPv4 address or CIDR covers them. These checks SHALL apply to the address the proxy resolves for a hostname, not just to IP-literal requests. The proxy SHALL deny a request for a hostname that is not on the allowlist without resolving it, so that a denied request produces no DNS query. The proxy SHALL permit only ports 80 and 443, and `CONNECT` only to 443.

#### Scenario: Denied names are not resolved

- **WHEN** a request for `https://<random>.example.net/` is sent through the proxy and that name is not allowlisted
- **THEN** the proxy answers 403 without issuing a DNS query for the name

#### Scenario: Cloud metadata

- **WHEN** `curl http://169.254.169.254/` runs in the agent container
- **THEN** the proxy answers 403

#### Scenario: Allowlisted name resolving to loopback

- **GIVEN** `localhost` is in the policy
- **WHEN** a request for `http://localhost/` is sent through the proxy
- **THEN** the proxy answers 403

#### Scenario: Private IP literal

- **WHEN** a request for `http://10.0.0.1/` is sent through the proxy and no CIDR entry covers it
- **THEN** the proxy answers 403

### Requirement: Composes with the --gh auth-proxy sidecar

When `--api` is passed and the `--gh` sidecar is active, the gh sidecar SHALL additionally be attached to the session's internal network. The agent container's `--add-host` entries for `github.com`, `api.github.com` and `uploads.github.com` SHALL point at the gh sidecar's address on that network. The egress proxy SHALL resolve the same three hostnames to that address, so that proxied GitHub traffic reaches the gh sidecar and still carries the injected credential. The gh sidecar's address SHALL be exempt from the private-range deny.

#### Scenario: GitHub API through both sidecars

- **GIVEN** `--gh --api` with a host token, and a policy listing `api.github.com`
- **WHEN** `curl --cacert <session CA> https://api.github.com/zen` runs in the agent container
- **THEN** TLS verifies against the gh sidecar's session CA
- **AND** GitHub's response reaches the client, which proves the gh sidecar forwarded the request upstream

### Requirement: Fail-closed lifecycle

The internal network, the outbound network and the proxy sidecar SHALL be named per session (`claude-egress-<id>`, `claude-egress-out-<id>`, `claude-egress-proxy-<id>`) and removed by the EXIT trap, which SHALL be installed before any of them is created. Failure to create either network, to start the proxy, or to detect it accepting connections within 15 seconds, or the proxy exiting during startup, SHALL abort the session before the agent container starts. It SHALL never fall back to unfiltered egress. The startup prune SHALL remove stopped `claude-egress-proxy-*` containers and unused `claude-egress-*` networks.

#### Scenario: Proxy fails to start

- **WHEN** the proxy sidecar exits during startup
- **THEN** `run.sh` exits non-zero, prints the proxy's last log lines, and never starts the agent container

#### Scenario: Teardown

- **WHEN** an `--api` session exits
- **THEN** no `claude-egress-*` container or network from that session remains

### Requirement: Denied hosts are reported to the user

`run.sh` SHALL print the effective allowlist and the proxy sidecar's name to stderr at startup. When the session ends, it SHALL print every distinct host the proxy denied during the session, together with `CLAUDE_DOCKER_EGRESS_POLICY` and the policy file's path.

#### Scenario: End-of-session summary

- **GIVEN** a session in which `example.org` was denied
- **WHEN** the session exits
- **THEN** stderr contains `egress policy blocked:` followed by a list that includes `example.org`, and names `CLAUDE_DOCKER_EGRESS_POLICY`
