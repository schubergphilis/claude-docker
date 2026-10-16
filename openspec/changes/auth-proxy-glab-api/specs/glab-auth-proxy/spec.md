# Spec Delta

## Purpose

Keep the host's GitLab token out of the agent container under `--glab` by holding it in the per-session auth proxy sidecar, which injects authentication in transit so `glab` and `git` keep working against the discovered GitLab host.

## ADDED Requirements

### Requirement: GitLab token is isolated from the agent container

When `--glab` is passed and a host token is found, the token SHALL be given only to the sidecar's environment, never forwarded into the agent container. The agent container SHALL get `GITLAB_TOKEN=claude-docker-proxy` so `glab` treats itself as authenticated. The sidecar SHALL remove every client-supplied `Authorization`, `PRIVATE-TOKEN` and `JOB-TOKEN` header before forwarding, so the placeholder never reaches GitLab.

#### Scenario: Token not visible inside the agent container

- **GIVEN** the host has a GitLab token for `gitlab.example.com` (env or host `glab`)
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `echo $GITLAB_TOKEN` inside the agent container prints `claude-docker-proxy`
- **AND** the host token appears nowhere in `/proc/1/environ`, in the environment of any process, or under `/root/.config/glab-cli/` inside the agent container

#### Scenario: Placeholder never reaches GitLab

- **GIVEN** the sidecar is active
- **WHEN** a request carrying `PRIVATE-TOKEN: claude-docker-proxy` is made to the proxied GitLab host from the agent container
- **THEN** the request reaches GitLab without a `PRIVATE-TOKEN` header and without the placeholder in any header

### Requirement: GitLab host is redirected through the sidecar

The agent container SHALL resolve the GitLab host the token belongs to (the host `--glab` token discovery settled on, with its port) to the sidecar via `--add-host`. No other hostname SHALL be redirected for GitLab. The sidecar SHALL terminate TLS for that host on that port with the session CA, the same root `--gh` uses. When the host is plain `http://` or an IP literal, `run.sh` SHALL exit with an error naming `--glab-direct`.

#### Scenario: Redirection is scoped to the discovered host

- **GIVEN** the token was discovered for `gitlab.example.com`
- **WHEN** the agent container resolves `gitlab.example.com` and `registry.gitlab.example.com`
- **THEN** the first resolves to the sidecar and the second resolves normally

#### Scenario: Non-default port is preserved

- **GIVEN** `GITLAB_HOST=gitlab.example.com:8443` and a token for it
- **WHEN** `glab api /version` runs inside the agent container
- **THEN** the request reaches the sidecar on port 8443 and is forwarded to `https://gitlab.example.com:8443`
- **AND** TLS verifies against the session CA

#### Scenario: Unsupported host form fails closed

- **GIVEN** a token is found and the GitLab host is `http://gitlab.internal` or `10.0.0.5`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `run.sh` exits non-zero with an error suggesting `--glab-direct`
- **AND** no container starts and the token is not forwarded

### Requirement: GitLab credentials are injected per path class

The sidecar SHALL inject `Authorization: Bearer <token>` on paths under `/api/` (REST and GraphQL). It SHALL inject `Authorization: Basic base64(oauth2:<token>)` on git smart-HTTP and git-LFS paths (`info/refs`, `git-upload-pack`, `git-receive-pack`, `info/lfs/…`). It SHALL forward every other path with no credential.

#### Scenario: glab and git work authenticated

- **GIVEN** the sidecar is active with a valid host token
- **WHEN** `glab api /user` and a `git push` to a private `https://gitlab.example.com/...` remote run inside the agent container
- **THEN** both succeed as the token's identity without a credential prompt

#### Scenario: Web paths carry no credential

- **GIVEN** the sidecar is active
- **WHEN** a `GET` for `https://gitlab.example.com/group/project/-/tree/main` is made from the agent container
- **THEN** the request reaches GitLab with no `Authorization`, `PRIVATE-TOKEN` or `JOB-TOKEN` header

### Requirement: Mounted glab config carries no tokens

While the GitLab proxy is active, the `config.yml` copy mounted into the agent container SHALL have the value of every key whose name ends in `token` blanked, for every host, in addition to the existing `use_keyring: false` rewrite. The host file SHALL NOT be modified.

#### Scenario: Tokens for other hosts are not exposed

- **GIVEN** host glab's `config.yml` stores tokens for `gitlab.example.com` and `gitlab.com`
- **WHEN** user runs `claude-docker --glab ~/repo` and the proxy is active for `gitlab.example.com`
- **THEN** `/root/.config/glab-cli/config.yml` inside the agent container contains neither token
- **AND** its other keys match the host file apart from `use_keyring`

### Requirement: GitLab request filtering policy

The sidecar SHALL block project and group deletion on the proxied host by default. Blocked requests are `DELETE`s whose raw, still percent-encoded request URI matches `^/+api/v4/(projects|groups)/[^/?]+/*(\?.*)?$`, so a numeric id and a URL-encoded path are both caught. They SHALL get a `403` whose body names the claude-docker glab-proxy policy. `CLAUDE_DOCKER_GLAB_POLICY` SHALL name a Caddyfile snippet imported into the GitLab site block. A set but unreadable path SHALL be a startup error.

#### Scenario: Project deletion is blocked by default

- **WHEN** `glab api -X DELETE /projects/123` or `glab api -X DELETE /projects/group%2Fsub%2Fproject` runs inside the agent container
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** the request never reaches GitLab

#### Scenario: Group deletion is blocked by default

- **WHEN** `glab api -X DELETE /groups/42` runs inside the agent container
- **THEN** the response is `403` and the request never reaches GitLab

#### Scenario: Non-destructive requests pass

- **WHEN** `glab mr list` and `glab api /user` run inside the agent container
- **THEN** both succeed

#### Scenario: User-supplied policy extension is honoured

- **GIVEN** `CLAUDE_DOCKER_GLAB_POLICY` points to a snippet blocking `DELETE` on `^/api/v4/projects/[^/]+/repository/branches/.*`
- **WHEN** a matching request is made from the agent container
- **THEN** it is answered `403` by the sidecar

### Requirement: GitLab proxy fails closed

If a GitLab token was found but the sidecar fails to start, rejects its config, or is not ready within the startup timeout, `run.sh` SHALL tear down the session resources and exit with an error. It SHALL NOT fall back to forwarding the token. If no token was found, `run.sh` SHALL keep today's no-token behaviour (warning, no `GITLAB_TOKEN`) and SHALL NOT add a GitLab site to the sidecar.

#### Scenario: Sidecar failure is fatal

- **GIVEN** a GitLab token was found and `CLAUDE_DOCKER_GLAB_POLICY` names a snippet Caddy rejects
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `run.sh` exits non-zero and prints the sidecar's error
- **AND** the token was never forwarded into any container

#### Scenario: No token means no GitLab site

- **GIVEN** no GitLab token can be discovered
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the agent container starts without `GITLAB_TOKEN` and the GitLab host resolves normally

### Requirement: GitLab requests are logged

Every request the sidecar proxies to GitLab SHALL be logged in the session's sidecar audit log (method, host, path, status). The log SHALL NOT contain the token or any `Authorization` / `PRIVATE-TOKEN` value.

#### Scenario: API call appears in the audit log

- **WHEN** `glab api /user` runs inside the agent container
- **THEN** `$RUNTIME logs claude-auth-proxy-<id>` shows an entry with host `gitlab.example.com`, method `GET`, path `/api/v4/user` and status `200`
- **AND** no entry contains the token
