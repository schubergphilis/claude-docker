# api-egress-policy Specification

## Purpose

Make the model traffic of an `--api --egress-lock` session provable. The agent container's only ways off its internal network are a per-session squid forward proxy, run from its own image, which logs every connection it carries, Claude Code's model requests included, and the auth-proxy sidecar, whose upstreams are fixed. The proxy allows the `ANTHROPIC_BASE_URL` endpoint, refuses the model providers' own hosts and leaves other hosts open, and Claude Code's managed settings keep its model traffic on that endpoint. Under the separate `--egress-allowlist` opt-in, the proxy instead refuses every host except the endpoint and the entries of one host-side allowlist file, resolves no name off that list, and checks before startup that the internal network's DNS is closed. The proxy's log is saved on the host as the session's evidence. Sessions without `--egress-lock`, including plain `--api` sessions, are unaffected.

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

Under `--egress-lock`, `run.sh` SHALL exit 1 before creating any container resource when `ANTHROPIC_BASE_URL` is unset or empty, when its host is not a hostname or IPv4 address of at most 253 characters made of letters, digits, `-` and `.`, when its port is not a number from 1 to 65535, or when its host, compared case-insensitively, is `anthropic.com`, `claude.ai` or `claude.com` or a subdomain of one. The endpoint's port is the one in `ANTHROPIC_BASE_URL`, or the scheme's default (80 for `http`, 443 otherwise). Without `--egress-allowlist`, the proxy SHALL allow the `ANTHROPIC_BASE_URL` host on the endpoint's port, and on 80/443, then deny `.anthropic.com`, `.claude.ai` and `.claude.com`, then allow every other destination that the metadata, loopback and port rules permit. HTTPS SHALL be proxied by `CONNECT` without TLS interception.

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

The proxy SHALL deny destinations in `169.254.0.0/16`, `fe80::/10`, `127.0.0.0/8`, `0.0.0.0/8` and `::1`, the metadata addresses `100.100.100.200` (Alibaba Cloud) and `fd00:ec2::254` (AWS IPv6), and the hostnames `metadata.google.internal` and `metadata.azure.internal`, above every allow rule. These checks SHALL apply to the address the proxy resolves for a hostname, not just to IP-literal requests. Without `--egress-allowlist`, private ranges SHALL be reachable. The proxy SHALL permit only ports 80 and 443, and `CONNECT` only to 443, except the endpoint's port for the `ANTHROPIC_BASE_URL` host and the ports the allowlist ports requirement adds; those exceptions SHALL come after the metadata, link-local and loopback denies.

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

### Requirement: --egress-allowlist needs --egress-lock and a file

`--egress-allowlist` SHALL turn on the allowlist mode of the egress proxy. Without `--egress-lock`, `run.sh` SHALL exit 1 before creating any container resource. With `--egress-lock`, it SHALL exit 1 before creating any container resource when neither `--egress-allowlist=FILE` nor `CLAUDE_DOCKER_EGRESS_ALLOWLIST` names a file.

#### Scenario: Allowlist without the lock

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-allowlist needs --egress-lock`, and no container starts

#### Scenario: No file named

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST` is unset
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-allowlist needs a file`, and no container starts

#### Scenario: File given with a space

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist $HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 and suggests `--egress-allowlist=FILE`

### Requirement: Sessions without --egress-allowlist are unchanged

Without `--egress-allowlist`, `run.sh` SHALL NOT read `CLAUDE_DOCKER_EGRESS_ALLOWLIST`, SHALL generate the same squid config as before this change, and SHALL save the same `.meta` keys and no `.conf` file.

#### Scenario: Same config as before

- **WHEN** `run.sh` generates the squid config for `--api --egress-lock`, `--api --egress-lock` with an endpoint port, and `--api --glab --egress-lock`
- **THEN** each is byte-identical to a fixture generated from the commit before this change

#### Scenario: Env var ignored

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST=/nonexistent`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock ~/repo`
- **THEN** no error mentions the allowlist, and the session's `.meta` has the same keys as before this change

### Requirement: Only the effective allowlist is allowed

Under `--egress-allowlist`, the proxy SHALL refuse every request whose host is not on the effective allowlist: the `ANTHROPIC_BASE_URL` host, `claude-docker-api-proxy` under `--api`, and the allowlist file's entries. A private-range destination SHALL be reachable only through a name on the effective allowlist or an endpoint that is a private IPv4 address.

#### Scenario: Listed and unlisted hosts

- **GIVEN** `$HOME/team.allow` lists `example.com`
- **WHEN** a `--egress-allowlist=$HOME/team.allow` session requests `https://example.com/`, `https://example.org/` and `http://example.org/` through the proxy
- **THEN** the first is allowed and the other two are refused

#### Scenario: Endpoint with an empty file

- **GIVEN** `ANTHROPIC_BASE_URL=https://gw.example.eu:8443` and an empty `$HOME/team.allow`
- **WHEN** a `--api --egress-lock --egress-allowlist=$HOME/team.allow` session sends `CONNECT gw.example.eu:8443` through the proxy
- **THEN** it is allowed

#### Scenario: Sidecar name on another port

- **WHEN** a `--api --egress-lock --egress-allowlist=$HOME/team.allow` session requests `http://claude-docker-api-proxy:9999/`
- **THEN** it is refused

#### Scenario: IP-literal requests

- **WHEN** an `--egress-allowlist` session requests `http://10.0.0.5/`, `http://2130706433/` and `http://[2001:db8::1]/`
- **THEN** each is refused

#### Scenario: IPv4 endpoint

- **GIVEN** `ANTHROPIC_BASE_URL=https://10.0.0.5:8443` and an empty `$HOME/team.allow`
- **WHEN** a `--api --egress-lock --egress-allowlist=$HOME/team.allow` session sends `CONNECT 10.0.0.5:8443`, `CONNECT 10.0.0.5:9443` and `CONNECT 10.0.0.6:8443`
- **THEN** the first is allowed and the other two are refused

#### Scenario: Listed on-prem name

- **GIVEN** `$HOME/team.allow` lists `git.corp.example`, which resolves to `10.20.1.2`
- **WHEN** the session requests `https://git.corp.example/`
- **THEN** it is allowed, and the access log shows a connect attempt to `10.20.1.2`

### Requirement: Credential flags add no hosts

Under `--egress-allowlist`, no credential flag SHALL add a host to the effective allowlist.

#### Scenario: --tfe without its host listed

- **GIVEN** an empty `$HOME/team.allow`
- **WHEN** a `--api --tfe --egress-lock --egress-allowlist=$HOME/team.allow` session requests `https://app.terraform.io/`
- **THEN** it is refused

#### Scenario: --gh-direct without GitHub listed

- **GIVEN** an empty `$HOME/team.allow`
- **WHEN** a `--api --gh-direct --egress-lock --egress-allowlist=$HOME/team.allow` session requests `https://github.com/`
- **THEN** it is refused

### Requirement: --gh and --glab need their sidecar's hosts in the file

Under `--egress-allowlist`, when the auth-proxy sidecar runs for `--gh` or `--glab` (a token was found), `run.sh` SHALL exit 1 before creating any container resource, naming the missing hosts, if any of `github.com`, `api.github.com` and `uploads.github.com`, or the proxied GitLab host, is not covered by an entry. An exact entry or a covering `.suffix`, with or without a port, SHALL count.

#### Scenario: GitLab host missing

- **GIVEN** `GITLAB_TOKEN=t`, `GITLAB_HOST=gitlab.corp.example` and an empty `$HOME/team.allow`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --glab --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `gitlab.corp.example`, and no container starts

#### Scenario: Entries that don't cover GitHub

- **GIVEN** `GH_TOKEN=t` and `$HOME/team.allow` listing `.github.io`, `notgithub.com` and `uploads.github.com`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `github.com` and `api.github.com` only

#### Scenario: One GitHub host missing

- **GIVEN** `GH_TOKEN=t` and `$HOME/team.allow` listing `github.com` and `api.github.com`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `uploads.github.com` only

#### Scenario: GitHub covered by a suffix

- **GIVEN** `GH_TOKEN` holds a valid token and `$HOME/team.allow` lists `.github.com`
- **WHEN** an `--api --gh --egress-lock --egress-allowlist=$HOME/team.allow` session clones a repository over HTTPS
- **THEN** the clone succeeds through the sidecar

#### Scenario: GitLab host on its own port

- **GIVEN** `GITLAB_TOKEN=t`, `GITLAB_HOST=gitlab.corp.example:8443` and `$HOME/team.allow` listing `.corp.example`
- **WHEN** a `--api --glab --egress-lock --egress-allowlist=$HOME/team.allow` session requests `https://gitlab.corp.example:8443/`
- **THEN** it is allowed, and `https://gitlab.corp.example:9443/` is refused

### Requirement: Sidecar upstream overrides are refused

Under `--egress-allowlist`, `run.sh` SHALL exit 1 before creating any container resource when `CLAUDE_DOCKER_GH_UPSTREAM` or `CLAUDE_DOCKER_GLAB_UPSTREAM` is set.

#### Scenario: GitHub upstream override

- **GIVEN** `CLAUDE_DOCKER_GH_UPSTREAM=https://other.example` and `$HOME/team.allow` listing the GitHub hosts
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `CLAUDE_DOCKER_GH_UPSTREAM`

### Requirement: Sidecar policy snippets lie outside every workspace

Under `--egress-allowlist`, the files named by `CLAUDE_DOCKER_GH_POLICY` and `CLAUDE_DOCKER_GLAB_POLICY` SHALL pass the same resolve, containment and control-byte checks as the allowlist file, or `run.sh` SHALL exit 1 before creating any container resource. The bytes read for the check SHALL be the bytes staged for the sidecar.

#### Scenario: Policy snippet inside the workspace

- **GIVEN** `CLAUDE_DOCKER_GH_POLICY=$HOME/repo/gh.caddy` and `$HOME/team.allow` listing the GitHub hosts
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `CLAUDE_DOCKER_GH_POLICY` and the workspace

### Requirement: Allowlist rule order

Under `--egress-allowlist`, the proxy's rules SHALL be in this order: the cache-manager deny; the metadata-name deny; a deny of every name not on the effective allowlist; the metadata, link-local and loopback address denies; the provider-host deny; the allows for the endpoint, sidecar and entry ports; the port denies; the allow of the effective allowlist's names; and a final deny of everything.

#### Scenario: Without a sidecar

- **WHEN** `run.sh` generates the squid config for `--api-direct --egress-lock --egress-allowlist=$HOME/team.allow`
- **THEN** its `http_access` lines contain the endpoint allow, no `claude-docker-api-proxy` rule, and end in `deny all`

#### Scenario: Provider host in another spelling

- **WHEN** an `--egress-allowlist` session requests `https://API.Anthropic.com/` and `https://api.anthropic.com./`
- **THEN** both are refused

#### Scenario: Listed name resolving to metadata

- **GIVEN** `$HOME/team.allow` lists a name that resolves to `169.254.169.254`
- **WHEN** the session requests that name
- **THEN** it is refused

#### Scenario: Loopback with a port

- **GIVEN** `$HOME/team.allow` lists `localhost:8080`
- **WHEN** the session requests `http://localhost:8080/`
- **THEN** it is refused

### Requirement: Names off the effective allowlist are not resolved

Under `--egress-allowlist`, the proxy SHALL send no DNS query, forward or reverse, for a request whose host is not a name on the effective allowlist, on any port.

#### Scenario: Secret in an unlisted name

- **WHEN** an `--egress-allowlist` session requests `https://secret.attacker.example/`, `http://SECRET.attacker.example/`, `http://secret.attacker.example:8080/`, `CONNECT secret.attacker.example:8443`, `https://1.2.3.4.secret.attacker.example/`, `http://10.0.0.5/` and `http://[2001:db8::1]/`
- **THEN** each is refused, and the proxy's resolver receives no query for any of them

### Requirement: Allowlist ports

Under `--egress-allowlist`, every name on the effective allowlist SHALL be reachable on 80 and 443, with `CONNECT` only to 443, plus: the endpoint host on the endpoint's port, `claude-docker-api-proxy` on 8080, the `--glab` host on its own port, and, for an entry written with `:port`, that port for the names the entry covers. No other port SHALL be reachable.

#### Scenario: Listed host on its own port

- **GIVEN** `$HOME/team.allow` lists `git.corp.example:8443`
- **WHEN** the session requests `https://git.corp.example:8443/`, `https://git.corp.example/`, `https://git.corp.example:9443/` and `https://example.com:8443/`
- **THEN** the first two are allowed and the last two are refused

#### Scenario: Suffix with a port

- **GIVEN** `$HOME/team.allow` lists `.corp.example:8443`
- **WHEN** the session requests `https://git.corp.example:8443/` and `https://git.corp.example:9443/`
- **THEN** the first is allowed and the second is refused

### Requirement: Allowlist file selection

The allowlist file SHALL be `FILE` from `--egress-allowlist=FILE`, else the path in `CLAUDE_DOCKER_EGRESS_ALLOWLIST`. A leading `~/` in either SHALL be expanded to `$HOME/`. No other file SHALL be read.

#### Scenario: File from the env var

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST=$HOME/team.allow`, listing `pypi.org`
- **WHEN** `run.sh` generates the squid config for `--api --egress-lock --egress-allowlist`
- **THEN** `egress_allowed_names` contains `pypi.org`

#### Scenario: Flag file wins

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST` names a file listing `pypi.org`, and `$HOME/other.allow` lists `example.com`
- **WHEN** `run.sh` generates the squid config for `--egress-allowlist=$HOME/other.allow`
- **THEN** `egress_allowed_names` contains `example.com` and not `pypi.org`

#### Scenario: Tilde in the flag value

- **WHEN** the user passes `--egress-allowlist=~/team.allow` with the `~` unexpanded by the shell
- **THEN** `run.sh` reads `$HOME/team.allow`

#### Scenario: No fixed fallback file

- **GIVEN** `$XDG_CONFIG_HOME/claude-docker/egress-allowlist` exists and `CLAUDE_DOCKER_EGRESS_ALLOWLIST` is unset
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-allowlist needs a file`

### Requirement: The allowlist file is a readable text file

`run.sh` SHALL exit 1 before creating any container resource, naming the path and its source, when the allowlist file is not a readable regular file, has a symlink chain longer than 40 links, or contains NUL or control bytes other than CR, LF and TAB.

#### Scenario: Missing file

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=/nonexistent ~/repo`
- **THEN** `run.sh` exits 1 with `not a readable regular file` and `/nonexistent`

#### Scenario: Directory as file

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME ~/repo`
- **THEN** `run.sh` exits 1 with `not a readable regular file`

#### Scenario: Control bytes

- **GIVEN** `$HOME/team.allow` contains a NUL byte, or the byte 0x1f
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming the file

### Requirement: The allowlist file is read once and hashed

`run.sh` SHALL read the allowlist file once, and hash and parse the same bytes, including a last line without a newline. It SHALL hash with `sha256sum`, else `shasum -a 256`, and SHALL exit 1 before creating any container resource when neither is available.

#### Scenario: Hash matches the file

- **GIVEN** a `$HOME/team.allow` with CRLF line endings whose last line, `pypi.org`, has no newline
- **WHEN** an `--egress-allowlist=$HOME/team.allow` session starts
- **THEN** its `.meta` has `allowlist_sha256=` equal to `sha256sum` of the file, and `pypi.org` is on the effective allowlist

#### Scenario: No hash tool

- **GIVEN** neither `sha256sum` nor `shasum` is on `PATH`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming the missing tool

#### Scenario: Only shasum

- **GIVEN** only `shasum` is on `PATH`
- **WHEN** an `--egress-allowlist=$HOME/team.allow` session starts
- **THEN** `allowlist_sha256` equals `sha256sum` of the file

### Requirement: The allowlist file lies outside every workspace

`run.sh` SHALL resolve the allowlist file's own symlinks and its directory's, resolve each workspace the same way, and exit 1 before creating any container resource, naming the workspace, when the file lies inside any workspace the session mounts, read-only or not, compared on a `/` boundary.

#### Scenario: File inside the workspace

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/repo/allow ~/repo`
- **THEN** `run.sh` exits 1 naming `~/repo`

#### Scenario: Symlinked workspace

- **GIVEN** `~/work` is a symlink to `/data/work`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=/data/work/allow ~/work`
- **THEN** `run.sh` exits 1 naming the workspace

#### Scenario: Symlink into the workspace

- **GIVEN** `$HOME/team.allow` is a symlink to `$HOME/repo/allow`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming the workspace

#### Scenario: Read-only second workspace

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/docs/allow ~/repo --ro ~/docs`
- **THEN** `run.sh` exits 1 naming `~/docs`

#### Scenario: Sibling directory

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/repo2/allow ~/repo`
- **THEN** the file is accepted

### Requirement: Allowlist entry grammar

Every allowlist entry SHALL be a hostname or a `.suffix` of at least two labels, either with an optional `:port` from 1 to 65535. A host SHALL use only letters, digits, `-` and `.`, be at most 253 characters, have labels of 1-63 characters that neither start nor end with `-`, and have no trailing dot. Entries SHALL be lowercased before they are checked. Blank lines, whole-line and trailing `#` comments, leading and trailing spaces and tabs, and a trailing CR SHALL be ignored.

#### Scenario: Every entry form

- **GIVEN** `$HOME/team.allow` with the lines `# team list`, `PyPI.org  # index`, `.corp.example`, `git.example.com:8443` and `.internal.example:8443`
- **WHEN** `run.sh` generates the squid config for `--egress-allowlist=$HOME/team.allow`
- **THEN** `egress_allowed_names` contains `pypi.org`, `.corp.example`, `git.example.com` and `.internal.example`, and port ACLs exist for `git.example.com` and `.internal.example` on 8443

#### Scenario: Overlapping entries

- **GIVEN** `$HOME/team.allow` lists `api.example.com`, `.example.com`, `pypi.org` and `pypi.org`
- **WHEN** `run.sh` generates the squid config
- **THEN** `egress_allowed_names` contains `.example.com` and `pypi.org` once each and not `api.example.com`, and the proxy image's `squid -k parse` reports no warning

#### Scenario: Comment without a space

- **GIVEN** `$HOME/team.allow` with the lines `pypi.org#index` and `example.org<TAB>#c`
- **WHEN** `run.sh` generates the squid config
- **THEN** `egress_allowed_names` contains `pypi.org` and `example.org`

#### Scenario: Boundary values

- **GIVEN** `$HOME/team.allow` lists a 253-character host made of labels of 63, 63, 63 and 61 characters, `a.example:1` and `b.example:65535`
- **WHEN** the user starts an `--egress-allowlist=$HOME/team.allow` session
- **THEN** the entries are accepted

### Requirement: An invalid allowlist entry is fatal

An entry outside the grammar, a host whose last label is all digits or `0x` plus hex digits, or an entry equal to or under `anthropic.com`, `claude.ai` or `claude.com` in any case SHALL make `run.sh` exit 1 before creating any container resource. `run.sh` SHALL name the file and line of every invalid entry.

#### Scenario: Wildcard spelling

- **GIVEN** line 3 of `$HOME/team.allow` is `*.example.com`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1, stderr names the file with `:3`, and suggests `.example.com`

#### Scenario: Several invalid lines

- **GIVEN** lines 2 and 5 of `$HOME/team.allow` are invalid
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** stderr names both `:2` and `:5`

#### Scenario: Invalid hosts and ports

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo` with a file whose only line is, in turn, `-a.example.com`, `a-.example.com`, `a..example.com`, `a_b.example.com`, `example.com.`, a 254-character name, a name with a 64-character label, `.com`, `example.com:`, `example.com:0`, `example.com:65536`, `example.com:http`, `https://example.com`, `example.com/x`, `example.com all`, `example.com<TAB>all` and `example.com<CR>x`
- **THEN** `run.sh` exits 1 each time, naming the file and line, and no rejected text reaches the generated config

#### Scenario: Addresses

- **WHEN** the user runs the same command with a file whose only line is, in turn, `10.0.0.5`, `167772165`, `10.5`, `0x7f000001` and `0X7F000001`
- **THEN** `run.sh` exits 1 each time, saying IP entries are not supported

#### Scenario: Provider hosts in any spelling

- **WHEN** the user runs the same command with a file whose only line is, in turn, `api.anthropic.com`, `API.Anthropic.com`, `.ANTHROPIC.com`, `.anthropic.com:8443`, `claude.ai`, `x.claude.ai` and `claude.com`
- **THEN** `run.sh` exits 1 each time, saying the lock refuses model providers' hosts

#### Scenario: Provider names as labels elsewhere

- **WHEN** the user runs the same command with a file listing `notanthropic.com` and `anthropic.com.corp.example`
- **THEN** both entries are accepted and the run reaches runtime detection

### Requirement: DNS is closed under --egress-allowlist

Under `--egress-allowlist`, before any sidecar starts, `run.sh` SHALL check with probe containers that an external name resolves from the session's outbound network, and that the internal network's resolver answers it without an address, each within a time limit. Any other outcome SHALL abort the session, naming DNS. The two probes SHALL have distinct per-session names, be removed by the EXIT trap and be covered by the startup prune.

#### Scenario: Engine forwards DNS

- **GIVEN** an engine whose internal networks resolve external names
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** `run.sh` aborts before the proxy starts, naming DNS as the reason

#### Scenario: DNS unavailable

- **GIVEN** the control lookup from the outbound network fails
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** `run.sh` aborts, saying the DNS check is inconclusive

#### Scenario: Probe times out or can't run

- **GIVEN** the internal probe's resolver times out, refuses the connection, or the probe can't run
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** `run.sh` aborts before the proxy starts

#### Scenario: DNS closed

- **GIVEN** an engine whose internal networks don't resolve external names
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** both probes pass and the session starts

### Requirement: Allowlist evidence is saved

Under `--egress-allowlist`, `run.sh` SHALL write the generated squid config to `<start>-<id>.conf` in the evidence directory, owner-only, before the agent container starts, and SHALL exit 1 before the proxy starts, naming the path, when the directory or the file can't be created or written. The session's `.meta` SHALL also have `allowlist_file` (the resolved path), `allowlist_sha256` and `allowlist_add_hosts` (the `--add-host` entries given to the proxy).

#### Scenario: Evidence of the list

- **GIVEN** `$HOME/team.allow` is a symlink to `/etc/team/allow`, and `CLAUDE_DOCKER_ADD_HOSTS=git.corp.example:10.0.0.5`
- **WHEN** an `--egress-allowlist=$HOME/team.allow` session exits
- **THEN** the `.meta` has `allowlist_file=/etc/team/allow`, its SHA-256 and `allowlist_add_hosts=` containing `git.corp.example:10.0.0.5`
- **AND** the `.conf` next to it, mode 600, is the config the proxy ran with

#### Scenario: Evidence directory can't be created

- **GIVEN** `XDG_STATE_HOME` points at a path under a regular file
- **WHEN** the user starts an `--egress-allowlist=$HOME/team.allow` session
- **THEN** `run.sh` exits 1 naming the evidence path, and the proxy never starts

#### Scenario: Evidence survives a failed log copy

- **GIVEN** an `--egress-allowlist` session whose engine can't return the proxy's log
- **WHEN** the session exits
- **THEN** the `.conf` file is still present
