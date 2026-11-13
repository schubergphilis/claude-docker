## Why

Under `--gh` the real token never reaches the agent container, but a compromised
session can still use it through the sidecar while the session runs. The default
policy blocks only repository deletion. The calls that do the most lasting
damage are open: a session can add its own SSH key, a deploy key, a
collaborator, a webhook to an outside URL, or a self-hosted runner, or transfer
or publish a repository, and all of these survive the session and the token's
revocation (#8, #212). The `--glab` policy has blocked the GitLab equivalents
since #196.

## What Changes

- The default `api.github.com` policy also refuses, with a `403` naming the
  claude-docker gh-proxy policy:
  - `POST` that adds SSH, GPG or signing keys, account emails (a verified one can
    receive a password reset), deploy keys, repository or organization webhooks,
    organization invitations, self-hosted runner registrations or JIT runner
    configs, or transfers a repository;
  - `PUT` that adds a collaborator, an organization member or a team member;
  - `PATCH` on a webhook or its config (repointing its URL);
  - `PATCH` on a bare repository or organization path. That is where visibility
    and access settings change, and Caddy can't read the body to tell those
    apart from harmless settings, so all of it is refused; `--gh-direct` changes
    them.
- Each route is matched under its numeric-id alias too (`/repositories/{id}`,
  `/organizations/{id}`).
- Docs: the policy's structural blind spots (GraphQL, `git push`, request
  bodies), a persistence hunt in the incident checklist, and a note that a
  `CLAUDE_DOCKER_GH_POLICY` snippet runs inside the token-bearing site.

Matching stays on the decoded path (`path_regexp`), which Caddy also cleans of
doubled slashes, so it covers more spellings than GitHub routes. Checked
against api.github.com on a sample of routes (`GET /user`, `PATCH` and
`DELETE` on a repository, the transfer, runner and invitation calls): its
router doesn't decode percent-escapes, merge slashes, fold case or accept a
trailing slash, and it ignores `X-HTTP-Method-Override` and `_method`. So the
GitLab policy's guards for escaped spellings and method overrides aren't
needed here.

Not in scope: GraphQL mutations, `git push` of `.github/workflows/*`, and other
writes that don't outlive the session (branch protection, secrets).

## Capabilities

### Modified Capabilities

- `gh-auth-proxy`: the default request policy also blocks calls that leave access
  or a data feed behind once the session ends, and repository or organization
  setting changes.

## Impact

- `run.sh` (generated `api.github.com` site), `tests/test_auth_proxy_caddyfile.py`
  (the gh site now runs under a real Caddy too), `tests/integration/gh-proxy-integration.sh`,
  `docs/auth.md`, `docs/security.md`.
- `gh repo edit`, `gh repo rename` and similar setting changes now need
  `--gh-direct`. Everything else that passed before still passes.
