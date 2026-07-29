# gh-auth-proxy

## ADDED Requirements

### Requirement: GitHub token is isolated from the agent container

When `--gh` is passed and a host token is found, the token SHALL be provided only to the sidecar proxy container's environment. It SHALL NOT be present in the agent container's environment, process table, or filesystem, and SHALL NOT be recoverable via `gh auth token` inside the agent container. The agent container SHALL receive the fixed placeholder `GH_TOKEN=claude-docker-proxy` so `gh` treats itself as authenticated; the sidecar SHALL replace any client-supplied `Authorization` header with the real one, so the placeholder value never reaches GitHub.

#### Scenario: Token not visible inside the agent container

- **GIVEN** the host has a GitHub token (env or `gh auth token`)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `echo $GH_TOKEN` inside the agent container prints `claude-docker-proxy`
- **AND** `gh auth token` inside the agent container does not output the host token
- **AND** the host token appears nowhere in `/proc/1/environ` inside the agent container

#### Scenario: gh and git still work authenticated

- **GIVEN** the sidecar is active with a valid host token
- **WHEN** `gh api /user` and a `git push` to a private `https://github.com/...` remote run inside the agent container
- **THEN** both succeed as the host token's identity, without any credential prompt

### Requirement: GitHub traffic is redirected through the sidecar with a per-session CA

The agent container SHALL resolve `github.com`, `api.github.com`, and `uploads.github.com` to the sidecar via `--add-host` entries; no other hostnames SHALL be redirected (pre-signed hosts such as `objects.githubusercontent.com` and `codeload.github.com` resolve normally and never receive the token). The sidecar SHALL terminate TLS for the three hostnames using a CA generated fresh for the session; the CA private key SHALL never leave the sidecar. The CA's public root certificate SHALL be installed into the agent container's system trust store by the entrypoint before privilege drop, and `NODE_EXTRA_CA_CERTS` SHALL point at it.

#### Scenario: Redirection is scoped to the three hostnames

- **WHEN** the agent container resolves `github.com`, `api.github.com`, and `uploads.github.com`
- **THEN** all three resolve to the sidecar's network address
- **AND** `objects.githubusercontent.com` resolves to a public GitHub address

#### Scenario: TLS verifies against the session CA

- **WHEN** `curl https://api.github.com/rate_limit` runs inside the agent container
- **THEN** it completes without certificate errors
- **AND** the presented certificate chains to the session's ephemeral root, not GitHub's public CA

### Requirement: Sessions are isolated and cleaned up

Each `run.sh` invocation with an active sidecar SHALL create its own container network and sidecar with names unique to the invocation (`claude-gh-<id>` / `claude-gh-proxy-<id>`). Concurrent sessions SHALL NOT share networks, sidecars, CAs, or token copies. On exit, `run.sh` SHALL remove the session's sidecar and network via the existing EXIT trap.

#### Scenario: Two concurrent sessions do not interfere

- **GIVEN** two simultaneous `claude-docker --gh` sessions
- **WHEN** both perform authenticated GitHub operations
- **THEN** each session's traffic transits only its own sidecar
- **AND** the two sidecars hold independent CAs (roots differ)

#### Scenario: Teardown removes session resources

- **WHEN** a `claude-docker --gh` session exits
- **THEN** its sidecar container and session network no longer exist

### Requirement: Works out of the box, fails closed

The sidecar SHALL run a digest-pinned upstream Caddy image (override: `CLAUDE_DOCKER_PROXY_IMAGE`) requiring no user-built image and no manual configuration beyond the existing `--gh` flag. If no host token is found, `run.sh` SHALL skip the sidecar silently and behave as the legacy no-token fallback. If a token was found but the sidecar fails to start or its CA cannot be retrieved within the startup timeout, `run.sh` SHALL tear down the session resources and exit with an actionable error; it SHALL NOT silently fall back to forwarding the real token into the agent container.

#### Scenario: First use requires no setup

- **GIVEN** a host that has never used the proxy but is authenticated with `gh`
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** the sidecar image is pulled automatically and authenticated GitHub access works with no additional steps

#### Scenario: Sidecar startup failure is fatal, not degraded

- **GIVEN** a host token was found but the sidecar cannot start (e.g. image unavailable)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `run.sh` exits non-zero with an error identifying the sidecar failure
- **AND** the real token is not forwarded into the agent container

### Requirement: Request filtering policy

The sidecar SHALL enforce request policy before forwarding. The default policy SHALL block repository deletion — `DELETE` requests matching `^/repos/[^/]+/[^/]+/?$` on `api.github.com` — with a `403` response whose body identifies the claude-docker proxy policy. All other requests SHALL pass. Users SHALL be able to extend policy by pointing `CLAUDE_DOCKER_GH_POLICY` at a Caddyfile snippet that is imported into the generated sidecar config. Policy configuration SHALL NOT be readable or writable from inside the agent container.

#### Scenario: Repo deletion is blocked by default

- **WHEN** `gh api -X DELETE /repos/someorg/somerepo` runs inside the agent container
- **THEN** the response is `403` with a body identifying the claude-docker gh-proxy policy
- **AND** the request never reaches GitHub

#### Scenario: Non-destructive requests pass

- **WHEN** `gh pr list` and `gh api /rate_limit` run inside the agent container
- **THEN** both succeed

#### Scenario: User-supplied policy extension is honoured

- **GIVEN** `CLAUDE_DOCKER_GH_POLICY` points to a snippet blocking `DELETE` on `^/repos/[^/]+/[^/]+/git/refs/.*`
- **WHEN** a matching request is made from the agent container
- **THEN** it is answered `403` by the sidecar

### Requirement: Proxied requests are logged

The sidecar SHALL log every proxied request (method, path, response status) as structured output on its stdout, retrievable via `$RUNTIME logs <sidecar>` for the lifetime of the session; logs are deliberately not persisted beyond the session. Logs SHALL NOT contain the token or `Authorization` header values. `run.sh` SHALL print the sidecar container name at session start so the log stream is discoverable.

#### Scenario: API call appears in the audit log

- **WHEN** `gh api /user` runs inside the agent container
- **THEN** `docker logs claude-gh-proxy-<id>` shows a structured entry with method `GET`, path `/user`, and status `200`
- **AND** no log entry contains the token

#### Scenario: Audit log is discoverable

- **WHEN** a `claude-docker --gh` session starts with an active sidecar
- **THEN** `run.sh` prints the sidecar container name before the agent session begins
- **AND** `$RUNTIME logs <printed name>` succeeds
