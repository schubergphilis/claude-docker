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

The agent container SHALL resolve the GitLab host the token belongs to (the host `--glab` token discovery settled on, with its port) to the sidecar via `--add-host`. For an exported `GITLAB_TOKEN`, that host SHALL be `GITLAB_HOST` when set, else glab's default host, and never the workspace's `origin` host. No other hostname SHALL be redirected for GitLab. The sidecar SHALL terminate TLS for that host on that port with the session CA, the same root `--gh` uses. When the host is plain `http://` (from `GITLAB_HOST` or the `origin` remote) or an IP literal, `run.sh` SHALL exit with an error naming `--glab-direct`.

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

#### Scenario: Exported token is not proxied for a non-GitLab origin

- **GIVEN** `GITLAB_TOKEN` is exported, `GITLAB_HOST` is unset and the workspace's `origin` is `git@github.com:org/repo.git`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the proxied host is glab's default host (`gitlab.com` when glab has none)
- **AND** `github.com` is not redirected to the sidecar

### Requirement: GitLab credentials are injected per path class

The sidecar SHALL inject `Authorization: Bearer <token>` on paths under `/api/` (REST and GraphQL). It SHALL inject `Authorization: Basic base64(oauth2:<token>)` on git smart-HTTP paths (`info/refs`, `git-upload-pack`, `git-receive-pack`). It SHALL forward every other path with no credential, git-LFS paths (`info/lfs/…`, `gitlab-lfs/…`) included: GitLab's LFS batch response hands a usable credential back to the client, so injecting there would expose one to the container. Git LFS against a private project therefore needs `--glab-direct`.

#### Scenario: glab and git work authenticated

- **GIVEN** the sidecar is active with a valid host token
- **WHEN** `glab api /user` and a `git push` to a private `https://gitlab.example.com/...` remote run inside the agent container
- **THEN** both succeed as the token's identity without a credential prompt

#### Scenario: Web paths carry no credential

- **GIVEN** the sidecar is active
- **WHEN** a `GET` for `https://gitlab.example.com/group/project/-/tree/main` is made from the agent container
- **THEN** the request reaches GitLab with no `Authorization`, `PRIVATE-TOKEN` or `JOB-TOKEN` header

#### Scenario: LFS paths carry no credential

- **GIVEN** the sidecar is active
- **WHEN** a `POST` to `https://gitlab.example.com/group/project.git/info/lfs/objects/batch` is made from the agent container with its own `Authorization` header
- **THEN** the request reaches GitLab with no `Authorization`, `PRIVATE-TOKEN` or `JOB-TOKEN` header

### Requirement: Mounted glab config carries no tokens

Under `--glab`, whether or not a token was found, the `config.yml` copy mounted into the agent container SHALL have the value of every key whose name ends in `token` blanked, for every host, in addition to the existing `use_keyring: false` rewrite. The host file SHALL NOT be modified.

#### Scenario: Tokens for other hosts are not exposed

- **GIVEN** host glab's `config.yml` stores tokens for `gitlab.example.com` and `gitlab.com`
- **WHEN** user runs `claude-docker --glab ~/repo` and the proxy is active for `gitlab.example.com`
- **THEN** `/root/.config/glab-cli/config.yml` inside the agent container contains neither token
- **AND** its other keys match the host file apart from `use_keyring`

#### Scenario: Tokens are blanked when no token was found

- **GIVEN** host glab's `config.yml` stores a token, but discovery finds none for the candidate hosts
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `/root/.config/glab-cli/config.yml` inside the agent container contains no token values

### Requirement: GitLab request filtering policy

The sidecar SHALL block project and group deletion on the proxied host by default. Blocked requests are `DELETE`s whose raw, still percent-encoded request URI matches `^/+api/v4/(projects|groups)/[^/?]+/*(\?.*)?$`, so a numeric id and a URL-encoded path are both caught. The sidecar SHALL also block, by default, the REST calls that create or rotate a token and return it: `POST` or `PUT` on `personal_access_tokens/:id/rotate` (`:id` may be `self`), `user/personal_access_tokens`, `users/:id/personal_access_tokens`, `users/:id/impersonation_tokens`, `(projects|groups)/:id/access_tokens` and `.../access_tokens/:id/rotate`, `(projects|groups)/:id/deploy_tokens`, `deploy_tokens`, and `groups/:id/service_accounts/:id/personal_access_tokens` (and its `rotate`), all under `/api/v4/`. These match on the raw request URI too, tolerating repeated slashes, a trailing slash and a query string. Token creation through GraphQL is not filtered. Blocked requests SHALL get a `403` whose body names the claude-docker glab-proxy policy and points at `CLAUDE_DOCKER_GLAB_POLICY` and `--glab-direct`. `CLAUDE_DOCKER_GLAB_POLICY` SHALL name a Caddyfile snippet imported into the GitLab site block. A set but unreadable path SHALL be a startup error.

#### Scenario: Project deletion is blocked by default

- **WHEN** `glab api -X DELETE /projects/123` or `glab api -X DELETE /projects/group%2Fsub%2Fproject` runs inside the agent container
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** the request never reaches GitLab

#### Scenario: Group deletion is blocked by default

- **WHEN** `glab api -X DELETE /groups/42` runs inside the agent container
- **THEN** the response is `403` and the request never reaches GitLab

#### Scenario: Token creation and rotation are blocked by default

- **WHEN** `glab api -X POST /personal_access_tokens/self/rotate`, `glab api -X POST /user/personal_access_tokens` or `glab api -X POST /projects/group%2Fp/access_tokens` runs inside the agent container
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** the request never reaches GitLab

#### Scenario: Non-destructive requests pass

- **WHEN** `glab mr list`, `glab api /user`, `glab api /personal_access_tokens` and `glab api -X POST /projects/1/issues` run inside the agent container
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
