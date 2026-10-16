# GitLab and model-endpoint auth through the proxy sidecar

## Why

`--glab` and `--api` still forward their secrets into the agent container as environment variables: `GITLAB_TOKEN`, and `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`. Any process in the container can read them with `printenv`. That includes the agent itself, which reads the model key on every request. Both are static header credentials on a hostname known up front, the case the `--gh` sidecar was built for. Its own proposal named GitLab as a near-1:1 port. Moving both behind the same sidecar removes the exfiltratable secret and keeps `glab`, `git` and Claude Code working unchanged.

## What Changes

- **One sidecar per session for every proxied service.** The `--gh` sidecar becomes a shared per-session auth proxy. `--gh`, `--glab` and `--api` each add their own site blocks to one Caddy instance, so a session has one network, one CA and one audit log. It is renamed to match: `claude-auth-<id>` / `claude-auth-proxy-<id>`, replacing `claude-gh-<id>` / `claude-gh-proxy-<id>`. The stale-resource prune sweeps both prefixes so strays from older versions are still cleaned up.
- **`--glab` keeps the token in the sidecar.** **BREAKING** (behavioural): the agent container gets `GITLAB_TOKEN=claude-docker-proxy`, not the real token.
  - The GitLab host the token belongs to is redirected to the sidecar via `--add-host`, port included. It is the host `--glab` already discovers.
  - The sidecar terminates TLS with the session CA. It injects `Authorization: Bearer <token>` on `/api/` and `Basic oauth2:<token>` on git smart-HTTP and LFS paths, and strips client credentials everywhere else.
  - The mounted glab `config.yml` copy has every token-valued key blanked, so tokens for other GitLab hosts stay out too.
  - Token discovery is unchanged.
- **`--glab` default policy and audit log.** The default policy blocks project and group deletion. `CLAUDE_DOCKER_GLAB_POLICY` extends it, mirroring `CLAUDE_DOCKER_GH_POLICY`.
- **`--api` keeps the gateway key in the sidecar.** **BREAKING** (behavioural): the agent container gets `ANTHROPIC_BASE_URL` pointing at the sidecar over the session-private network, plus `claude-docker-proxy` placeholders for whichever of `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` the host set.
  - The sidecar forwards to the host's `ANTHROPIC_BASE_URL`, default `https://api.anthropic.com`. It replaces `x-api-key` / `Authorization` with the real values and drops any credential the host did not provide, so a stray claude.ai OAuth bearer never reaches the gateway.
  - `CLAUDE_DOCKER_API_CA` is also given to the sidecar as an extra upstream trust root.
- **New escape hatches.** `--glab-direct` and `--api-direct` restore today's direct forwarding, like `--gh-direct`. Passing a flag together with its `-direct` form is a startup error. Each `-direct` mode gets its own statusline tag.
- **Fail-closed startup.** This applies to every proxied service. If a credential was found but the sidecar cannot start, `run.sh` exits with an error and never falls back to forwarding the secret.

## Capabilities

### New Capabilities

- `glab-auth-proxy`: how GitLab is proxied. Covers token isolation from the agent container, host redirection with the session CA, header injection per path class, sanitising the glab config copy, the default deletion policy and `CLAUDE_DOCKER_GLAB_POLICY`, and audit logging.
- `api-auth-proxy`: how the model endpoint is proxied. Covers key isolation, rewriting the base URL to the sidecar, replacing and dropping credential headers, upstream trust (`CLAUDE_DOCKER_API_CA`), streaming pass-through, and audit logging.

### Modified Capabilities

- `gh-auth-proxy`: "Sessions are isolated and cleaned up" and "Proxied requests are logged" move to the shared sidecar and network names (`claude-auth-proxy-<id>` / `claude-auth-<id>`). One sidecar serves every proxied service in the session. The `--gh`-specific requirements are otherwise unchanged.
- `external-cli-tools`:
  - "Credentials opt-in": `--glab` no longer forwards the real token and goes through the sidecar. `--glab-direct` is added.
  - "Custom model endpoint opt-in": `--api` no longer forwards the key and points `ANTHROPIC_BASE_URL` at the sidecar. `--api-direct` is added.
  - "Git credential helper per forge host": the `glab auth git-credential` helper moves from `--glab` to `--glab-direct`. Under `--glab` the sidecar injects auth on git paths, so git needs no helper, the same as `--gh`.
- `container-runtime`: "Static host entries for networks without DNS": `CLAUDE_DOCKER_ADD_HOSTS` reaches the shared auth-proxy sidecar, and the agent container also skips an entry for the proxied GitLab host under `--glab`.

## Non-goals

- `ANTHROPIC_CUSTOM_HEADERS` is still forwarded into the agent container. It is free-form, so its header names aren't known when the static Caddyfile is written. Gateways that authenticate through a custom header still expose that header, and the docs will say so.
- `--tfe`, `--az`, `--aws` and `--registry` are separate follow-ups.
- Private-CA GitLab upstreams, GitLab over plain `http://`, IP-literal `GITLAB_HOST`, and SSH remotes are not supported here. `--glab-direct` covers them; private-CA and SSH did not work under `--glab` before either.
- Refreshing short-lived glab OAuth tokens mid-session. The sidecar holds the token that was current at launch, the same as today's env forwarding.

## Impact

- `run.sh`:
  - The sidecar is generalised: per-service Caddyfile snippets, shared naming, and a readiness check that doesn't depend on a TLS site existing.
  - New `--glab-direct` / `--api-direct` flags and new `CLAUDE_DOCKER_GLAB_POLICY` env var, with help text updated.
  - Sanitised glab config staging and new statusline flags.
- `entrypoint.sh`: no change expected. The CA moves from `claude-docker-gh-proxy.crt` to `claude-docker-auth-proxy.crt`, and the entrypoint's install already matches it through the `claude-docker-*.crt` glob.
- Tests:
  - Extend `tests/test_gh_proxy_caddyfile.py`, `tests/test_glab_token.py`, `tests/test_api_optin.py`, `tests/test_masks.py` and `tests/bats/run.bats`.
  - Extend `tests/integration/gh-proxy-integration.sh`, or a generalised sibling, with mock GitLab and mock gateway upstreams. Test-only hook: `CLAUDE_DOCKER_GLAB_UPSTREAM`.
- Docs: `docs/auth.md` (GitLab and `--api` sections plus the proxy section), `docs/security.md` (threat-model bullets and the compromised-session runbook), `docs/usage.md`, and the README credential table.
- No new image or pin: the same pinned Caddy image is reused.
