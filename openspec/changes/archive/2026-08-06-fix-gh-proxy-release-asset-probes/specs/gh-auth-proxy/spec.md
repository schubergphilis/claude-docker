## MODIFIED Requirements

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
