# Tasks

## 1. Generalise the sidecar chassis (no new services yet)

- [x] 1.1 Rename the session resources to `claude-auth-<id>` / `claude-auth-proxy-<id>` in `create_stage` and the EXIT trap. Rename `prune_stale_gh` to sweep both the `claude-auth-` and the legacy `claude-gh-` prefixes. Verify with a BATS test (`tests/bats/run.bats`) that a stopped `claude-gh-proxy-x` and a `claude-auth-proxy-x` stray are both removed, and a running one is left alone.
- [x] 1.2 Split the Caddyfile into a constant root file (global options plus `import /etc/caddy/sites/*.caddy`) and a constant `gh.caddy` holding today's three site blocks, unchanged. Mount the staged `sites/` dir read-only. Update `tests/test_gh_proxy_caddyfile.py` so it asserts the root and `gh.caddy` are constant text and that the gh blocks are byte-identical to before.
- [x] 1.3 Replace CA-only readiness with "Caddy logged that it is serving its config", plus a CA copy when a TLS-intercepting service is active. Keep the early-exit log dump. First confirm the exact log line against the pinned 2.11.4 image, then verify that `tests/integration/gh-proxy-integration.sh` still passes, along with a new case for a sidecar with only an `http://` site.
  - _Status:_ Done. Readiness line confirmed against Caddy 2.11.4 and covered by bats (config-never-loads, api-only skips the CA); the integration harness passes in CI ([CI run 40773480271](https://github.com/schubergphilis/claude-docker/actions/runs/40773480271) at `ff7dee4`).
- [x] 1.4 Rename the CA mount to `claude-docker-auth-proxy.crt`, and add `NODE_EXTRA_CA_CERTS` / `UV_SYSTEM_CERTS` only when a TLS service is active. The entrypoint's `claude-docker-*.crt` glob needs no change. Verify that the gh integration harness still trusts the CA and that `curl https://api.github.com/rate_limit` succeeds in it.
  - _Status:_ Done. Covered by bats; the harness's phase 1 trusts the renamed CA and reaches `api.github.com` without `-k` in CI ([CI run 40773480271](https://github.com/schubergphilis/claude-docker/actions/runs/40773480271) at `ff7dee4`).
- [x] 1.5 Update the sidecar naming and audit-log references in `docs/auth.md`, `docs/security.md` and the run.sh help text. Verify with `grep -rn 'claude-gh-proxy' docs README.md run.sh`: the only hits left should be the legacy prune and its comment.

## 2. GitLab through the sidecar

- [x] 2.1 Add the `--glab-direct` flag: arg parsing, a conflict check against `--glab` in `validate_opts`, a `glab-direct` entry in `CLAUDE_DOCKER_FLAGS`, and help text. Unmask `/root/.config/glab-cli/` under either glab flag. Verify with `tests/test_masks.py` and a BATS case: `--glab --glab-direct` exits non-zero before any container starts.
- [x] 2.2 Compute the proxied GitLab host as `GITLAB_HOST`, else the host the token was discovered for, else the first candidate. Normalise it to `host[:port]`, rejecting `http://` and IP literals with an error that names `--glab-direct`. Under `--glab`, stop forwarding the real `GITLAB_TOKEN` and set the placeholder, while still forwarding `GITLAB_HOST` by name. Verify with `tests/test_glab_token.py` cases: explicit token, discovered token, `GITLAB_HOST` with a port, `https://` form, `http://` rejected, IP literal rejected, and placeholder in the agent's env.
- [x] 2.3 Write a constant `glab.caddy` with:
  - the `{$GLAB_PROXY_SITE}` address and `tls internal`
  - Bearer on `/api/*` and Basic `oauth2:` on git smart-HTTP paths, with credential headers stripped elsewhere (LFS paths included)
  - `-PRIVATE-TOKEN -JOB-TOKEN` on every path
  - the default project and group deletion `403`, the default token creation and rotation `403`, and an import of the always-staged `glab-policy.caddy`
  - access logs with request headers filtered out

  Add `CLAUDE_DOCKER_GLAB_POLICY` validation (set but unreadable is a startup error) and the `CLAUDE_DOCKER_GLAB_UPSTREAM` test hook. Pass `GLAB_PROXY_BEARER` / `GLAB_PROXY_BASIC` to the sidecar by bare name. Verify that a Caddyfile unit test asserts the snippet is constant and contains each matcher.
- [x] 2.4 Wire the agent container: `--add-host <glab host>:<sidecar ip>`, and join the network even when gh is not active. Verify with a GitLab mock in the integration harness:
  - `glab api /user` succeeds and the mock sees `Authorization: Bearer <token>` with no `PRIVATE-TOKEN`
  - `git ls-remote` sees Basic `oauth2:`
  - a web path sees no credential
  - `DELETE /api/v4/projects/123` and `DELETE /api/v4/projects/group%2Fsub%2Fp` get `403` without reaching the mock (pin the `%2F` behaviour here)
  - a non-443 port works
  - the token is absent from `/proc/1/environ`
  - _Status:_ Done. Every header and policy bullet is verified against real Caddy in `tests/test_auth_proxy_caddyfile.py`; harness phase 5 (`glab api /user`, git smart-HTTP, web path, the `%2F` DELETE, `/proc/1/environ`) passes in CI ([CI run 40773480271](https://github.com/schubergphilis/claude-docker/actions/runs/40773480271) at `ff7dee4`).
- [ ] 2.5 While proxied, blank every `*token:` value in the staged `config.yml` (`stage_glab_config`). Leave `--glab-direct` copies untouched. Verify with a unit test: a config with tokens for two hosts plus `oauth2_refresh_token` keeps every key, with all token values `""` and `use_keyring: false`. Also confirm by hand that glab with an OAuth-logged-in config plus a placeholder env token does not try a refresh.
  - _Status:_ Implemented and unit-tested in bats and `GlabProxied`. The manual OAuth-refresh check needs real credentials and is deferred to #227.
- [x] 2.6 Warn at startup when the staged config's `api_host` for the proxied host differs from that host. Verify with a `tests/test_glab_token.py` case.
- [x] 2.7 Check fail-closed and no-token behaviour. Verify with integration cases:
  - an invalid `CLAUDE_DOCKER_GLAB_POLICY` exits non-zero with Caddy's error, and the token appears in neither container
  - with no token found, no GitLab site is staged and the host resolves normally
  - _Status:_ Done. Covered by bats and `GlabProxied`, and by harness phase 6 (invalid policy, no token), which passes in CI ([CI run 40775594176](https://github.com/schubergphilis/claude-docker/actions/runs/40775594176) at `191a019`).
- [x] 2.8 Update the GitLab and proxy sections of `docs/auth.md`, the threat-model and compromised-session bullets in `docs/security.md`, `docs/usage.md` and the credential opt-in table in `docs/auth.md`. Document `--glab-direct`, `CLAUDE_DOCKER_GLAB_POLICY`, and the `api_host`, private-CA and OAuth-expiry limitations. Verify that `lychee` link checks pass and the docs reviewer finds no orphaned section.
- [x] 2.9 Move the `glab auth git-credential` helper from `--glab` to `--glab-direct`, and skip a `CLAUDE_DOCKER_ADD_HOSTS` entry for the proxied GitLab host in the agent container while still passing it to the sidecar. Verify with `tests/bats/run.bats` cases for `build_git_config` and `build_host_args`.

## 3. Model endpoint through the sidecar

- [x] 3.1 Add the `--api-direct` flag: parsing, a conflict check against `--api`, an `api-direct` flags entry, and help text. Apply the existing credential-required check and `CLAUDE_DOCKER_API_CA` handling to both flags. Verify with `tests/test_api_optin.py`: `--api --api-direct` is rejected, and `--api-direct` without a credential exits 1.
- [x] 3.2 Under `--api`, split the host `ANTHROPIC_BASE_URL` (default `https://api.anthropic.com`) into origin and path prefix. Stop forwarding the URL and both credentials. Set the agent's `ANTHROPIC_BASE_URL=http://claude-docker-api-proxy:8080` and `claude-docker-proxy` placeholders only for the credentials the host set non-empty, and add `--add-host claude-docker-api-proxy:<sidecar ip>`. Keep forwarding the remaining `ANTHROPIC_*` / `CLAUDE_CODE_*` variables by name. Verify with `tests/test_api_optin.py` cases on the agent env and on the argv of both containers (no credential values).
- [x] 3.3 Write a constant `api.caddy`:
  - the named site `http://claude-docker-api-proxy:8080`, with `rewrite * {$API_PROXY_PREFIX}{uri}` inside a `route`
  - `reverse_proxy {$API_PROXY_UPSTREAM}` with `header_up Host {upstream_hostport}` and an import of the staged `api-transport.caddy`
  - an import of the staged credential snippet (`request_header x-api-key "{env.API_PROXY_KEY}"` or `request_header -x-api-key`, and the same pair for `Authorization`)
  - logs with request headers filtered out

  Verify with a unit test that the snippet and the four credential one-liners are constant, and that staging picks the right pair for each host combination.
- [x] 3.4 Give the sidecar `CLAUDE_DOCKER_API_CA` read-only when set, through a staged `api-transport.caddy` with `tls_trust_pool file` listing the system bundle and the CA. When unset, stage an empty file. Verify with integration cases: an HTTPS mock signed by a test CA succeeds with the variable set, and fails verification without it.
- [x] 3.5 Verify the integration harness against a mock gateway at `https://<mock>/prefix`:
  - `POST /v1/messages` arrives as `/prefix/v1/messages` with the right `Host` and the injected credential
  - an `Authorization: Bearer <oauth>` from the client is stripped when only the API key is set
  - an SSE response streams incrementally, with the first event received before the mock closes
  - the key is absent from the agent's `/proc/1/environ` and from the sidecar logs
  - _Status:_ Done. Prefix, Host, credential swap and strip, SSE and log redaction are verified against real Caddy (an HTTPS mock with a test CA included); harness phase 5 passes in CI ([CI run 40773480271](https://github.com/schubergphilis/claude-docker/actions/runs/40773480271) at `ff7dee4`).
- [x] 3.6 Check fail-closed: with the proxy image overridden to a missing tag, `--api` exits non-zero naming `--api-direct`, and no container holds the key. Verify with an integration case.
  - _Status:_ Done. bats covers the start failure naming `--api-direct`; harness phase 6 runs `--api` with a missing proxy image and passes in CI ([CI run 40775594176](https://github.com/schubergphilis/claude-docker/actions/runs/40775594176) at `191a019`).
- [x] 3.7 Update the `--api` section of `docs/auth.md` and the threat model in `docs/security.md`. Document `--api-direct`, the plain-HTTP session hop, the one-time API-key approval prompt, and that `ANTHROPIC_CUSTOM_HEADERS` stays visible. Verify that `lychee` passes and the documented `claude-docker --api` example works against the mock.

## 4. Integration checks

- [x] 4.1 Run `claude-docker --gh --glab --api` against all three mocks in one session. Verify: exactly one `claude-auth-proxy-<id>` container and one `claude-auth-<id>` network exist; `gh`, `glab` and Claude Code requests all appear in one `docker logs` stream; and both are gone after exit.
  - _Status:_ Done. Harness phase 5 runs `--gh --glab --api` in one session: one sidecar, gh, glab and api requests in one audit log, nothing left after exit ([CI run 40775594176](https://github.com/schubergphilis/claude-docker/actions/runs/40775594176) at `191a019`).
- [x] 4.2 Run the local checks from CONTRIBUTING.md (shellcheck, hadolint, `python3 -m unittest discover -s tests`, `bats tests/bats`, smoke cell) and `openspec validate auth-proxy-glab-api --strict`. All must pass.
  - _Status:_ Done. shellcheck, hadolint, unittest, bats and the smoke cells (including the combined `aws+glab+tfe+api+az` cell, which starts a real sidecar) pass in CI ([CI run 40773480271](https://github.com/schubergphilis/claude-docker/actions/runs/40773480271) at `ff7dee4`); `openspec validate auth-proxy-glab-api --strict` passes.
- [ ] 4.3 Manual run with real credentials, recorded in the PR description:
  - `glab mr list` and `git push` on a self-hosted GitLab
  - a Claude Code session through the team's gateway
  - `printenv | grep -E 'GITLAB|ANTHROPIC'` shows only placeholders and the sidecar URL
  - _Status:_ Deferred to #227: it needs real credentials, which CI doesn't have.
