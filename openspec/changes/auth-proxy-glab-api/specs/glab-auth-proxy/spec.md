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

The agent container SHALL resolve the proxied GitLab host, with its port, to the sidecar via `--add-host`. No other hostname SHALL be redirected for GitLab. The sidecar SHALL terminate TLS for that host on that port with the session CA, the same root `--gh` uses. When the host is plain `http://` or an IP literal, `run.sh` SHALL exit with an error naming `--glab-direct`. When it is not a `host[:port]`, `run.sh` SHALL exit with an error.

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

#### Scenario: Malformed host is refused

- **GIVEN** a token is found and `GITLAB_HOST` is `evil.example.com/path` or contains a space or a brace
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `run.sh` exits non-zero with an error saying the host is not a valid `host[:port]`
- **AND** no container starts and the token is not forwarded

### Requirement: Proxied GitLab host is the host the token belongs to

The proxied host SHALL be `GITLAB_HOST` when set, else the host discovery found the token for. A token that is not bound to a host SHALL go to glab's default host (its `host:` key, else `gitlab.com`) and never to the workspace's `origin` host. Unbound tokens are an exported `GITLAB_TOKEN`, and a discovered token that glab returns for any host (`GITLAB_ACCESS_TOKEN`, `OAUTH_TOKEN`, a legacy top-level `token:`).

#### Scenario: Exported token is not proxied for a non-GitLab origin

- **GIVEN** `GITLAB_TOKEN` is exported, `GITLAB_HOST` is unset and the workspace's `origin` is `git@github.com:org/repo.git`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the proxied host is glab's default host (`gitlab.com` when glab has none)
- **AND** `github.com` is not redirected to the sidecar

#### Scenario: Host-agnostic glab token is not proxied for the origin

- **GIVEN** `GITLAB_TOKEN` and `GITLAB_HOST` are unset, host glab answers `GITLAB_ACCESS_TOKEN` for every host, and the workspace's `origin` is `https://github.com/org/repo.git`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the proxied host is glab's default host
- **AND** `github.com` is not redirected to the sidecar

#### Scenario: Origin-bound glab token keeps the origin

- **GIVEN** `GITLAB_TOKEN` and `GITLAB_HOST` are unset, host glab stores a token for `gitlab.example.com` only, and the workspace's `origin` is on `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the proxied host is `gitlab.example.com`

### Requirement: GitLab credentials are injected per path class

The sidecar SHALL inject `Authorization: Bearer <token>` on paths under `/api/` (REST and GraphQL), and `Authorization: Basic base64(oauth2:<token>)` on git smart-HTTP paths (`info/refs`, `git-upload-pack`, `git-receive-pack`). Every other path SHALL be forwarded with no credential, git-LFS paths (`info/lfs/…`, `gitlab-lfs/…`) included, because GitLab's LFS batch response hands a credential back to the client. Git LFS against a private project needs `--glab-direct`.

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

The sidecar SHALL answer `403`, without forwarding, a `DELETE` of a project or group, a `POST` to the same paths other than the project and group imports (GitLab honours `_method=delete` and `X-HTTP-Method-Override` on a `POST`), a REST `POST` or `PUT` that creates or rotates a token or adds an SSH, GPG or deploy key, a runner, a pipeline trigger, a cluster-agent token, a project or group member (added, imported or approved), invitation, LDAP or SAML group link, share, transfer, webhook, integration, push mirror or pipeline schedule, an access-request approval, an admin call that creates or edits a user or OAuth application or changes instance settings, a `PUT` on a bare project or group path (its settings), and a `DELETE`, `POST` or `PUT` whose path percent-encodes an unreserved character (`A-Z a-z 0-9 - . _ ~`), on the proxied host. The filter is best effort, not a guarantee that no durable credential can be obtained. Matching SHALL run on the raw, still percent-encoded request URI under `/api/v4/`, tolerating repeated slashes, a trailing slash, a `.json` suffix and a query string. Token creation through GraphQL is not filtered. The `403` body SHALL name the claude-docker glab-proxy policy.

#### Scenario: Project deletion is blocked by default

- **WHEN** `glab api -X DELETE /projects/123` or `glab api -X DELETE /projects/group%2Fsub%2Fproject` runs inside the agent container
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** the request never reaches GitLab

#### Scenario: Group deletion is blocked by default

- **WHEN** `glab api -X DELETE /groups/42` runs inside the agent container
- **THEN** the response is `403` and the request never reaches GitLab

#### Scenario: A method override cannot turn a POST into a deletion

- **WHEN** `POST /api/v4/projects/123` with `X-HTTP-Method-Override: DELETE`, or with a `_method=delete` form body, runs inside the agent container
- **THEN** the response is `403` and the request never reaches GitLab
- **AND** `POST /api/v4/projects/import` and `POST /api/v4/groups/import` are still forwarded

#### Scenario: Project and group settings changes are blocked by default

- **WHEN** `PUT /api/v4/projects/123?visibility=public` or `PUT /api/v4/groups/42` runs inside the agent container
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** `PUT /api/v4/projects/123/issues/1` is still forwarded

#### Scenario: An escaped unreserved character cannot hide a blocked call

- **WHEN** `DELETE /api/v4/%70rojects/123` or `POST /api/v4/user/personal%5Faccess%5Ftokens` runs inside the agent container
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** `GET /api/v4/projects/group%2Fp/repository/files/a%20b.txt/raw` and `GET /api/v4/projects/1/repository/files/app%2Fmodels%2Fkey%2Erb?ref=main` are still forwarded

#### Scenario: Durable credential creation is blocked by default

- **WHEN** a `POST` or `PUT` under `/api/v4/` runs inside the agent container on any of: `personal_access_tokens/:id/rotate` (`:id` may be `self`), `user/personal_access_tokens`, `users/:id/personal_access_tokens`, `users/:id/impersonation_tokens`, `(projects|groups)/:id/access_tokens` and `.../access_tokens/:id/rotate`, `(projects|groups)/:id/deploy_tokens`, `deploy_tokens`, `groups/:id/service_accounts/:id/personal_access_tokens` and its `rotate`, `user/keys`, `user/gpg_keys`, `user/emails`, `users/:id/emails`, `users/:id/keys`, `users/:id/gpg_keys`, `(projects|groups)/:id/deploy_keys` and `.../deploy_keys/:id/enable`, `user/runners`, `runners`, `runners/:id/reset_authentication_token`, `runners/reset_registration_token`, `(projects|groups)/:id/runners/reset_registration_token`, `projects/:id/triggers`, `projects/:id/cluster_agents/:id/tokens`, `deploy_keys`, `(projects|groups)/:id/members` and `.../invitations` (and `PUT` on a single member or invitation), `(projects|groups)/:id/share`, `.../transfer`, `.../hooks` (and `PUT` on a single hook), `.../access_requests/:id/approve`, `projects/:id/remote_mirrors` (and `PUT` on a single mirror), `projects/:id/mirror/pull`, `hooks`, `projects/:id/import_project_members/:id`, `(projects|groups)/:id/members/:id/approve`, `groups/:id/(ldap|saml)_group_links`, `(projects|groups)/:id/integrations` and the legacy `.../services` (and `PUT` on a single one), `projects/:id/pipeline_schedules` (and `PUT` on or `take_ownership` of a single one), `users` (and `PUT` on a single user), `applications`, `application/settings`
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** the request never reaches GitLab

#### Scenario: An absolute-form request target is matched like an origin-form one

- **WHEN** `DELETE https://gitlab.example.com/api/v4/projects/1 HTTP/1.1` is sent from the agent container
- **THEN** the response is `403` naming the claude-docker glab-proxy policy
- **AND** the request never reaches GitLab

#### Scenario: Path variants are blocked

- **WHEN** `DELETE /api/v4//projects/123`, `DELETE //api//v4/groups/42/`, `POST /api//v4/user/personal_access_tokens.json` or `POST /api/v4/projects/group%2Fp/access_tokens.json?x=1` is sent from the agent container
- **THEN** each response is `403` and no request reaches GitLab

#### Scenario: Non-destructive requests pass

- **WHEN** `glab mr list`, `glab api /user`, `glab api /personal_access_tokens` and `glab api -X POST /projects/1/issues` run inside the agent container
- **THEN** all of them succeed

### Requirement: GitLab policy is extensible

`CLAUDE_DOCKER_GLAB_POLICY` SHALL name a Caddyfile snippet imported into the GitLab site block. A set but unreadable path SHALL be a startup error. The default policy's `403` body SHALL point at `CLAUDE_DOCKER_GLAB_POLICY` and `--glab-direct`.

#### Scenario: User-supplied policy extension is honoured

- **GIVEN** `CLAUDE_DOCKER_GLAB_POLICY` points to a snippet blocking `DELETE` on `^/api/v4/projects/[^/]+/repository/branches/.*`
- **WHEN** a matching request is made from the agent container
- **THEN** it is answered `403` by the sidecar

#### Scenario: Unreadable policy path fails at startup

- **GIVEN** `CLAUDE_DOCKER_GLAB_POLICY` names a path that doesn't exist
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `run.sh` exits non-zero before any container starts

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
