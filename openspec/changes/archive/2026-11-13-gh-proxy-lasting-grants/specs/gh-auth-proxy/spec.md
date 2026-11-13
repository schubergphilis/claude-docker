## MODIFIED Requirements

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

## ADDED Requirements

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
