# gh-auth-proxy

## Purpose

Keep the host's GitHub token out of the agent container by holding it in a per-session sidecar proxy that injects authentication in transit. The sidecar terminates TLS for `github.com`, `api.github.com`, and `uploads.github.com` using an ephemeral per-session CA, injects the real `Authorization` header, and forwards to GitHub — so `gh` and `git` keep working unchanged while the exfiltratable secret never reaches the agent container. The sidecar also provides a policy point for blocking destructive API calls (e.g. repository deletion) and an audit log of every proxied request. This capability is deliberately GitHub-only and serves as the proof of concept for the broader credential-isolation sidecar pattern (per-session network/sidecar lifecycle, ephemeral CA and trust distribution, fail-closed startup, policy point, audit logging).

## Requirements

### Requirement: GitHub token is isolated from the agent container

When `--gh` is passed and a host token is found, the token SHALL be provided only to the sidecar proxy container's environment. It SHALL NOT be present in the agent container's environment, process table, or filesystem, and SHALL NOT be recoverable via `gh auth token` inside the agent container. The agent container SHALL receive the fixed placeholder `GH_TOKEN=claude-docker-proxy` so `gh` treats itself as authenticated; the sidecar SHALL replace any client-supplied `Authorization` header with the real one, so the placeholder value never reaches GitHub.

One request class is exempt from that injection. On `github.com`, a `HEAD` request whose path matches `^/[^/]+/[^/]+/releases/download/.+` SHALL be forwarded with the `Authorization` header **removed** rather than replaced, so it reaches GitHub anonymously. The header SHALL be deleted, not merely left uninjected: GitHub selects a release asset's CDN on the *presence* of an `Authorization` header regardless of its value, so forwarding the client's placeholder would have the same effect as forwarding the real token. A `HEAD` carrying any credential is answered with a redirect to a legacy `objects.githubusercontent.com` pre-signed URL that then fails `401` for every method, which makes release-asset URLs unusable for any client that probes with `HEAD` before `GET`.

The exemption SHALL be scoped to that method and path only. `GET` on the same path SHALL continue to receive the injected credential, as SHALL git smart-HTTP, git-LFS, `/archive/`, `/raw/`, and all `api.github.com` / `uploads.github.com` traffic. The exemption removes no authenticated capability: `github.com`'s web release-download endpoint does not honour token authentication, so an asset in a private repository is unreachable by that URL with or without the credential — the API asset endpoint (`GET /repos/{owner}/{repo}/releases/assets/{id}` with `Accept: application/octet-stream`, as used by `gh release download`) is the supported route and is unaffected.

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

#### Scenario: Release-asset HEAD probe is forwarded anonymously

- **GIVEN** the sidecar is active
- **WHEN** a `HEAD` request for `https://github.com/<owner>/<repo>/releases/download/<tag>/<asset>` is made from the agent container
- **THEN** the request reaches GitHub with no `Authorization` header, whether or not the client sent one
- **AND** the response redirects to `release-assets.githubusercontent.com` rather than `objects.githubusercontent.com`

#### Scenario: Release-asset GET keeps its injected credential

- **GIVEN** the sidecar is active
- **WHEN** a `GET` request for the same release-asset URL is made from the agent container
- **THEN** the request reaches GitHub carrying the injected `Basic base64(x-access-token:<token>)` header

#### Scenario: uv installs from a public release-asset URL with no flags

- **GIVEN** the sidecar is active
- **WHEN** `uvx --with https://github.com/<owner>/<repo>/releases/download/<tag>/<wheel> <tool>` runs inside the agent container with no additional flags or environment overrides
- **THEN** the wheel downloads and the tool runs

### Requirement: GitHub traffic is redirected through the sidecar with a per-session CA

The agent container SHALL resolve `github.com`, `api.github.com`, and `uploads.github.com` to the sidecar via `--add-host` entries; no other hostnames SHALL be redirected (pre-signed hosts such as `objects.githubusercontent.com`, `release-assets.githubusercontent.com` and `codeload.github.com` resolve normally and never receive the token). The sidecar SHALL terminate TLS for the three hostnames using a CA generated fresh for the session; the CA private key SHALL never leave the sidecar. The CA's public root certificate SHALL be installed into the agent container's system trust store by the entrypoint before privilege drop.

Because the intercepted hostnames are presented with a certificate chaining to that session root, clients that do not consult the system trust store SHALL be pointed at it explicitly. `NODE_EXTRA_CA_CERTS` SHALL point at the installed root for node-based tooling, and `UV_SYSTEM_CERTS=1` SHALL be set so `uv` — whose rustls client otherwise trusts only its bundled webpki roots and would fail every intercepted request with `invalid peer certificate: UnknownIssuer` — reads the system store instead. Both SHALL be set only when the sidecar is active. Certificate verification SHALL remain enabled in all cases; no configuration SHALL disable it for the intercepted hostnames.

#### Scenario: Redirection is scoped to the three hostnames

- **WHEN** the agent container resolves `github.com`, `api.github.com`, and `uploads.github.com`
- **THEN** all three resolve to the sidecar's network address
- **AND** `objects.githubusercontent.com` resolves to a public GitHub address

#### Scenario: TLS verifies against the session CA

- **WHEN** `curl https://api.github.com/rate_limit` runs inside the agent container
- **THEN** it completes without certificate errors
- **AND** the presented certificate chains to the session's ephemeral root, not GitHub's public CA

#### Scenario: A client with its own root store trusts the session CA

- **GIVEN** the sidecar is active
- **WHEN** `uv` fetches a URL on an intercepted hostname inside the agent container
- **THEN** it completes without certificate errors and with verification still enabled
- **AND** `UV_SYSTEM_CERTS=1` is present in the agent container's environment

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

The sidecar SHALL enforce request policy before forwarding, and answer a refused request with a `403` whose body identifies the claude-docker gh-proxy policy. The default policy SHALL block repository deletion on `api.github.com`: `DELETE` on `/repos/{owner}/{repo}` or its numeric-id alias `/repositories/{id}`. Users SHALL be able to extend policy with a `CLAUDE_DOCKER_GH_POLICY` Caddyfile snippet. Policy configuration SHALL NOT be readable or writable from inside the agent container.

#### Scenario: Repo deletion is blocked by default

- **WHEN** `gh api -X DELETE /repos/someorg/somerepo` runs inside the agent container
- **THEN** the response is `403` with a body identifying the claude-docker gh-proxy policy
- **AND** the request never reaches GitHub

#### Scenario: Repo deletion by numeric id is blocked by default

- **WHEN** `gh api -X DELETE /repositories/123456` runs inside the agent container
- **THEN** the response is `403` with a body identifying the claude-docker gh-proxy policy
- **AND** the request never reaches GitHub

#### Scenario: Non-destructive requests pass

- **WHEN** `gh pr list`, `gh pr create` and `gh api /rate_limit` run inside the agent container
- **THEN** all succeed

#### Scenario: User-supplied policy extension is honoured

- **GIVEN** `CLAUDE_DOCKER_GH_POLICY` points to a snippet blocking `DELETE` on `^/repos/[^/]+/[^/]+/git/refs/.*`
- **WHEN** a matching request is made from the agent container
- **THEN** it is answered `403` by the sidecar
- **AND** the default policy still applies

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

### Requirement: Default policy blocks lasting grants and setting changes

The default policy SHALL block, on `api.github.com`, the REST calls that leave access or a data feed behind once the session ends, and `PATCH` on a bare repository or organization path, which is where visibility and access settings change. Each blocked route SHALL also be blocked under its numeric-id alias (`/repositories/{id}`, `/organizations/{id}`), with a query string, and with a trailing slash.

#### Scenario: Adding keys or an email is blocked

- **WHEN** a `POST` to `/user/keys`, `/user/gpg_keys`, `/user/ssh_signing_keys` or `/user/emails` is made from the agent container
- **THEN** the response is `403` from the sidecar and the request never reaches GitHub

#### Scenario: Repository and organization grants are blocked

- **WHEN** a `POST` to a repository's `keys`, `hooks`, `transfer`, `actions/runners/registration-token` or `actions/runners/generate-jitconfig`, or to an organization's `hooks`, `invitations` or the same runner paths, is made from the agent container
- **THEN** the response is `403` from the sidecar and the request never reaches GitHub

#### Scenario: Adding collaborators or members is blocked

- **WHEN** a `PUT` to `/repos/{owner}/{repo}/collaborators/{user}`, `/orgs/{org}/memberships/{user}`, `/orgs/{org}/teams/{team}/memberships/{user}` or `/teams/{id}/memberships/{user}` is made from the agent container
- **THEN** the response is `403` from the sidecar

#### Scenario: Repointing a webhook is blocked

- **WHEN** a `PATCH` to a repository's or organization's `hooks/{id}` or `hooks/{id}/config` is made from the agent container
- **THEN** the response is `403` from the sidecar

#### Scenario: Setting changes are blocked

- **WHEN** `gh repo edit --visibility public` runs inside the agent container, or any `PATCH` to `/repos/{owner}/{repo}` or `/orgs/{org}`
- **THEN** the response is `403` from the sidecar, whose body names `--gh-direct` as the way to change settings

#### Scenario: Ordinary writes pass

- **WHEN** issues, pull requests, comments, refs or file contents are created or updated from the agent container, or a collaborator or deploy key is removed
- **THEN** the requests reach GitHub
