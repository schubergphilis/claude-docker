# egress-allowlist

## ADDED Requirements

### Requirement: Egress allowlist is opt-in

`run.sh` SHALL enable egress filtering only when `--egress-allowlist` is passed or `CLAUDE_DOCKER_EGRESS=allowlist` is set. Any other non-empty `CLAUDE_DOCKER_EGRESS` value SHALL be a startup error. Without either, the agent container's networking SHALL be unchanged from before this capability existed. When active, `egress` SHALL appear in `CLAUDE_DOCKER_FLAGS`.

#### Scenario: Default is unchanged

- **WHEN** user runs `claude-docker ~/repo` with `CLAUDE_DOCKER_EGRESS` unset
- **THEN** no `claude-egress-*` network or sidecar is created and no proxy env vars are set in the agent container

#### Scenario: Env knob enables it

- **WHEN** user runs `CLAUDE_DOCKER_EGRESS=allowlist claude-docker ~/repo`
- **THEN** the session runs with the egress allowlist active, exactly as with `--egress-allowlist`

#### Scenario: Typo is rejected

- **WHEN** user runs `CLAUDE_DOCKER_EGRESS=alowlist claude-docker ~/repo`
- **THEN** `run.sh` exits non-zero before creating any container, naming the accepted value

#### Scenario: Podman is refused

- **WHEN** the selected runtime is `podman` and the allowlist is requested
- **THEN** `run.sh` exits non-zero before creating any resource, stating the flag is not yet supported on podman

### Requirement: The network is the boundary

When active, the agent container SHALL be attached only to a per-session network created with `--internal`, so that it has no route off the host. A client that ignores the proxy environment variables SHALL NOT reach any external host, including allowlisted ones, and SHALL NOT resolve external hostnames. No capability SHALL be added to the agent container.

#### Scenario: Raw client cannot bypass the proxy

- **GIVEN** `example.com` is allowlisted
- **WHEN** `curl --noproxy '*' https://example.com` runs in the agent container
- **THEN** it fails without receiving an HTTP response

#### Scenario: External DNS does not resolve

- **WHEN** `getent hosts example.com` runs in the agent container
- **THEN** it fails

#### Scenario: Capability posture unchanged

- **WHEN** the allowlist is active
- **THEN** the agent process's `CapBnd` is still `00000000000000c5` and `CapEff` is `0`

### Requirement: Forward-proxy sidecar enforces a default-deny allowlist

A per-session squid sidecar, run from the agent image with `--entrypoint squid`, as a non-root user, with all capabilities dropped, `no-new-privileges`, no published ports, and its config mounted read-only, SHALL be attached to the internal network and to a per-session non-internal bridge. The agent container SHALL receive `HTTP_PROXY`, `HTTPS_PROXY`, `http_proxy`, `https_proxy` pointing at the sidecar and `NO_PROXY`/`no_proxy` covering loopback. The sidecar SHALL permit only requests to allowlisted hosts on allowed ports (80, 443, plus explicit operator-tier ports), SHALL tunnel TLS via `CONNECT` without terminating it, and SHALL deny everything else with HTTP 403.

#### Scenario: Allowlisted host reachable through the proxy

- **WHEN** `curl https://api.anthropic.com/` runs in the agent container with the proxy env
- **THEN** the proxy's `CONNECT` answer is 200 and an HTTP response is received from the origin

#### Scenario: Non-allowlisted host is denied

- **WHEN** `curl https://example.org/` runs in the agent container with the proxy env and `example.org` is not allowlisted
- **THEN** the proxy answers the `CONNECT` with 403

### Requirement: Allowlist sources and trust tiers

The allowlist SHALL be the union of: a built-in base set covering Claude Code's required Anthropic hosts (`.anthropic.com`, `.claude.ai`, `.claude.com`); hosts implied by each active opt-in (`--gh`/`--gh-direct`: `github.com`, `api.github.com`, `uploads.github.com`, `codeload.github.com`, `.githubusercontent.com`; `--glab`: `.gitlab.com`; `--tfe`: `app.terraform.io`; `--aws`: `.amazonaws.com`, `.awsapps.com`); operator-tier entries from `CLAUDE_DOCKER_EGRESS_ALLOW` (comma- or space-separated `host` or `host:port`) and the host part of `ANTHROPIC_BASE_URL` when set; and an approved per-project file. Operator-tier entries SHALL be exempt from the private-address and IP-literal denies; all other tiers SHALL NOT be.

#### Scenario: Opt-in adds its hosts

- **WHEN** user runs `claude-docker --egress-allowlist --tfe ~/repo`
- **THEN** `app.terraform.io` is reachable through the proxy and it is not without `--tfe`

#### Scenario: Operator entry may be internal

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOW=nexus.corp:8081` and `nexus.corp` resolves to `10.1.2.3`
- **THEN** requests to `nexus.corp:8081` are permitted

#### Scenario: Gateway host from ANTHROPIC_BASE_URL

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.example.net:4000/v1`
- **THEN** `llm.example.net` is in the operator tier and port 4000 is allowed

### Requirement: Per-project allowlist requires host-side approval

`run.sh` SHALL read `<first workspace>/.claude-docker/allowed-hosts` (one host per line, `#` comments, blank lines ignored) as a proposal. Every entry SHALL be validated before use: characters `[A-Za-z0-9.-]` only, optional single leading `.` for a suffix, at most 253 characters, no empty label, no leading `-`, at least one letter, at least one dot after any leading `.`; an invalid entry SHALL abort the run naming the line. The normalised list (sorted, de-duplicated, one host per line, newline-terminated) SHALL be identified by its SHA-256. A list whose hash is recorded in `${XDG_CONFIG_HOME:-$HOME/.config}/claude-docker/egress-approved` SHALL be used. Otherwise, interactively, `run.sh` SHALL print the hosts and require an explicit `y` before using the list and recording the hash; non-interactively, the list SHALL be ignored with a warning. If the approval store lies inside a mounted workspace, it SHALL be neither read nor written.

#### Scenario: Unapproved list is ignored non-interactively

- **GIVEN** the project file lists `example.com` and its hash is not recorded
- **WHEN** `run.sh` runs without a TTY
- **THEN** a warning names the file and `example.com` is denied by the proxy

#### Scenario: Approved list is honoured

- **GIVEN** the project file's normalised hash is recorded in the approval store
- **THEN** `example.com` is reachable through the proxy

#### Scenario: Edited list re-prompts

- **GIVEN** an approved list gains a new host
- **THEN** its hash no longer matches and approval is requested again

#### Scenario: Injection attempt is rejected

- **GIVEN** a project file line `example.com http_access allow all`
- **THEN** `run.sh` aborts naming that line and no sidecar is started

### Requirement: Unconditional denies precede every allow

The proxy SHALL deny, before any allow rule: the names `metadata.google.internal`, `metadata.azure.internal`, `metadata`; any destination resolving to `169.254.0.0/16`, `fe80::/10`, or `fd00:ec2::254`; and any port outside the allowed set. After the operator-tier allow and before the remaining allows, it SHALL deny IP-literal targets and targets any of whose resolved addresses is private, loopback, CGNAT, multicast, or reserved. Domain ACLs SHALL NOT fall back to reverse DNS for IP-literal requests.

#### Scenario: Metadata IP denied even with permissive list

- **GIVEN** `--aws` is active
- **WHEN** `curl http://169.254.169.254/` runs in the agent container with the proxy env
- **THEN** the proxy answers 403

#### Scenario: Rebinding to a private address is denied

- **GIVEN** an approved project host resolves to `10.0.0.5`
- **THEN** requests to it are denied

### Requirement: Composition with the gh auth-proxy sidecar

When both the allowlist and the `--gh` sidecar are active, the gh sidecar SHALL additionally join the internal network, the three `--add-host` entries SHALL point at its internal-network address, and the forward proxy SHALL resolve `github.com`, `api.github.com`, `uploads.github.com` to that same address and admit exactly that name/address pairing ahead of the private-address deny. Those names SHALL NOT be placed in `NO_PROXY` (clients match `NO_PROXY` entries as domain suffixes, which would strand other `*.github.com` hosts). The agent container SHALL remain attached only to the internal network.

#### Scenario: gh traffic still reaches the auth proxy

- **WHEN** user runs `claude-docker --egress-allowlist --gh ~/repo` with a host token
- **THEN** `api.github.com` requests from the agent, made through the proxy, complete TLS against the session CA alone (i.e. reach the gh sidecar), `codeload.github.com` is reachable through the proxy, and the agent has no other network

### Requirement: Lifecycle is fail-closed and leak-free

Egress resources SHALL be named from the session stage-dir suffix, covered by the EXIT trap before creation (gh sidecar removed before the egress network), and included in the stopped-only startup prune. Failure to create either network, start or connect the sidecar, observe squid accepting connections within 15 seconds, or read its internal address SHALL abort the run without starting the agent container; an exited sidecar's log tail SHALL be shown.

#### Scenario: Missing squid fails closed

- **GIVEN** an agent image built without squid
- **WHEN** the allowlist is requested
- **THEN** `run.sh` exits non-zero, no agent container starts, and no `claude-egress-*` resources remain

### Requirement: Denials are reported to the user

At startup `run.sh` SHALL print that the allowlist is active and name the sidecar. After the agent container exits, `run.sh` SHALL print each host the proxy denied during the session once, together with the project file path and `CLAUDE_DOCKER_EGRESS_ALLOW` as the places to allow it, and SHALL then exit with the agent container's exit status.

#### Scenario: Denied hosts listed at exit

- **GIVEN** the session attempted `example.org`, which is not allowlisted
- **WHEN** the agent container exits
- **THEN** stderr lists `example.org` and names `.claude-docker/allowed-hosts` and `CLAUDE_DOCKER_EGRESS_ALLOW`
