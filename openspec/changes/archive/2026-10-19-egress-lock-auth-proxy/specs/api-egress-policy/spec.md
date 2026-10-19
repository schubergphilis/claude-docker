# Spec Delta

## MODIFIED Requirements

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

### Requirement: Claude Code's endpoint can't be moved by the workspace

Under `--egress-lock`, `run.sh` SHALL refuse an `ANTHROPIC_BASE_URL` with any character outside RFC 3986's unreserved, reserved (except `[` and `]`) and `%`. It SHALL mount Claude Code managed settings read-only at `/etc/claude-code/managed-settings.json` whose `env` sets `ANTHROPIC_BASE_URL` to the session's endpoint (under `--api`, to `http://claude-docker-api-proxy:8080`, the auth-proxy sidecar whose only upstream is that endpoint) and `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX` and `CLAUDE_CODE_USE_FOUNDRY` to `0`. Sessions without `--egress-lock` SHALL NOT get this file.

#### Scenario: A project setting doesn't move the model traffic

- **GIVEN** an `--egress-lock` session whose workspace `.claude/settings.json` sets `ANTHROPIC_BASE_URL` to another host, or switches on Bedrock, Vertex or Foundry with a base URL of its own
- **WHEN** Claude Code sends a model request
- **THEN** the request goes to the session's endpoint, not to the project's host

#### Scenario: Under --api the pin is the sidecar

- **GIVEN** an `--api --egress-lock` session
- **WHEN** the agent reads `/etc/claude-code/managed-settings.json`
- **THEN** its `ANTHROPIC_BASE_URL` is `http://claude-docker-api-proxy:8080`, not the host's endpoint

#### Scenario: The agent can't change the managed settings

- **GIVEN** an `--egress-lock` session
- **WHEN** the agent tries to write `/etc/claude-code/managed-settings.json` or create a file in `/etc/claude-code`
- **THEN** both fail

#### Scenario: A URL that needs escaping is refused

- **GIVEN** `ANTHROPIC_BASE_URL` contains a `"`, a backslash, a quote or whitespace
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

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
