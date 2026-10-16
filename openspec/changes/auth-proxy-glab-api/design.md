# Design

## Context

See proposal.md (Why) for motivation. The sidecar that `--gh` starts today is built entirely in `run.sh`:

- **`create_stage`** names the network and sidecar `claude-gh-<id>` / `claude-gh-proxy-<id>` and installs the EXIT trap before anything exists.
- **`start_gh_sidecar`** writes a constant Caddyfile (quoted heredoc) and starts Caddy.
  - Per-run values reach Caddy through env: `{$VAR}` is substituted at config load, `{env.VAR}` per request.
  - The token goes in by bare name, so it is never written to disk or argv.
- **Readiness** is taken to be the moment the CA root can be `docker cp`'d out. That works only because every gh site uses `tls internal`.
- **Wiring:** the agent container joins the session network. Each GitHub hostname gets an `--add-host` entry, and the root is mounted as `claude-docker-gh-proxy.crt` and installed by the entrypoint.
- **`prune_stale_gh`** sweeps stopped `claude-gh-proxy-*` containers and empty `claude-gh-*` networks.

`--glab` today mounts the host glab dir read-only and overlays a staged `config.yml` copy with `use_keyring: false`. It forwards `GITLAB_TOKEN` (env or discovered) and `GITLAB_HOST`. `--api` forwards a fixed list of `ANTHROPIC_*` variables by name and fails closed when neither credential is set.

## Goals / Non-Goals

**Goals:**

- Reuse the gh chassis as it is: lifecycle, trap-before-create, fail-closed startup, the session CA, the audit log and the pinned Caddy image. Generalise it, don't rewrite it.
- Keep the Caddy config constant text. Per-run variation comes only from env values and from which constant snippet files are staged.
- No visible change for `--gh` users beyond the resource names.

**Non-Goals:**

- A generic plug-in mechanism for arbitrary services. `--tfe` and `--az` will add snippets the same way, but no abstraction is built for them now.
- Changing `CLAUDE_DOCKER_GH_POLICY` semantics, or the GitHub path classes and the release-asset `HEAD` exception.

## Decisions

### 1. One sidecar per session, not one per service

Every proxied flag adds site blocks to a single Caddy instance, renamed `claude-auth-proxy-<id>` on `claude-auth-<id>`.

- **Why:** one CA to distribute, one network the agent joins, and one audit log to point users at. It also keeps a single startup path to keep fail-closed.
- **Alternative considered:** a sidecar per service. An agent container can join several networks, but it would need N CAs installed, N readiness loops and N trap entries, with no isolation gained. Every sidecar belongs to the same session and the same trust domain anyway.
- **Trade-off:** one bad snippet (for example a broken `CLAUDE_DOCKER_GLAB_POLICY`) takes down every proxied service in the session. That is acceptable because startup fails closed and the error names the snippet.

Functions are renamed to match (`start_auth_sidecar`, `prune_stale_auth_proxy`). The prune filters on both the `claude-auth-` and the legacy `claude-gh-` prefixes. The CA mount becomes `claude-docker-auth-proxy.crt`.

### 2. Caddyfile composed from constant snippet files

`run.sh` writes a small constant root Caddyfile that holds the global options and `import /etc/caddy/sites/*.caddy`. It then stages only the snippet files for the active services into `$stage/auth-proxy/sites/`:

- `gh.caddy`: today's three site blocks, unchanged
- `glab.caddy`
- `api.caddy`

Each snippet is a quoted heredoc constant. Per-service policy files (`gh-policy.caddy`, `glab-policy.caddy`) are always staged, empty when unset, and imported from their own site block, exactly as now.

- **Alternative considered:** generating site blocks by string interpolation. Rejected because it would put shell-expanded host data into config text, and the test suite asserts the config is constant.
- **GitLab site address:** `{$GLAB_PROXY_SITE}`, for example `gitlab.example.com:8443`. Caddy substitutes `{$VAR}` in site addresses at config load.

### 3. Readiness without depending on a TLS site

An `--api`-only session has no `tls internal` site, so Caddy may never create a CA and the current "CA is copyable" check would time out. Readiness becomes two checks:

1. Caddy logs `serving initial configuration` (confirmed against 2.11.4), read with `$RUNTIME logs`.
2. If any TLS-intercepting service is active (gh or glab), the CA root is also copied out.

The early-exit detection (the container is gone, so dump its logs) is unchanged. `NODE_EXTRA_CA_CERTS` / `UV_SYSTEM_CERTS` and the CA mount are added only when a TLS-intercepting service is active.

- **Alternative considered:** a dummy `tls internal` site so the CA always exists. Rejected as a hack that would silently install a trust root nothing uses.

### 4. GitLab: header injection per path class

- **`/api/*`:** `Authorization: Bearer <token>`. GitLab accepts both PATs and OAuth access tokens as Bearer on REST and GraphQL, so one form covers what `glab auth login` and `GITLAB_TOKEN` produce.
- **Git and LFS paths:** these get `Authorization: Basic base64(oauth2:<token>)`. The match is `path_regexp` on `/(info/refs|git-upload-pack|git-receive-pack)$` and `/info/lfs/`. `oauth2` works as the username for both PATs and OAuth tokens. Git then never sees a `401` and never prompts, so `--glab` needs no git credential helper. `--glab-direct` keeps the host-scoped `glab auth git-credential` helper.
- **Everything else:** forwarded with `Authorization`, `PRIVATE-TOKEN` and `JOB-TOKEN` removed. Web UI paths don't accept token auth in a way the tools use. Injecting the token there would only widen what a compromised session can do (session-less web actions) without serving `glab` or `git`.
- **Client credentials:** the route first runs `request_header -Authorization`, `-PRIVATE-TOKEN` and `-JOB-TOKEN` on every request, then sets `Authorization` per path class. glab sends a PAT as `PRIVATE-TOKEN` and an OAuth token as `Authorization`; neither survives.
- **Host header:** client and upstream share the hostname, so the `Host` header passes through untouched, as it does for gh.
- **Header values:** computed on the host as `GLAB_PROXY_BEARER` / `GLAB_PROXY_BASIC` (`tr -d '\n'` after base64) and handed over by bare name, the same as gh.
- **Policy:** the default policy matches deletion of a project or group, numeric id or URL-encoded path. Prototyping against Caddy 2.11.4 showed that `path_regexp` sees the *decoded* path, so `DELETE /projects/group%2Fp` would slip past it. The matcher is therefore `vars_regexp {http.request.uri} ^/+api/v4/(projects|groups)/[^/?]+/*(\?.*)?$` on the raw URI, which also catches `//api/...` and trailing slashes.
- **Ordering:** the whole site body sits inside `route { }`. Caddy otherwise sorts directives (`handle` before `respond`, and same-name directives by matcher), which would let a top-level `respond` policy, or a user snippet, run after proxying. Inside `route` the order is literal: strip client credentials, inject per path class, apply policy, proxy.

### 5. Sanitised glab config

The existing `stage_glab_config` sed gains one more expression under `--glab`, also when no token was found. Every key matching `^\s*[A-Za-z0-9_]*token:` gets its value replaced by `""`. That catches `token`, `oauth2_refresh_token` and `job_token` for every host. Blanking only the proxied host would mean parsing YAML in shell; tokens for other hosts have no business in the container under `--glab` anyway.

`glab` reads `GITLAB_TOKEN` from env ahead of config, so the placeholder wins. A blank `oauth2_refresh_token` can't trigger a refresh, because glab doesn't refresh env-supplied tokens. A task verifies this against an OAuth-logged-in config.

### 6. `--api`: rewrite the base URL instead of intercepting TLS

Inside the agent container, `ANTHROPIC_BASE_URL=http://claude-docker-api-proxy:8080`. The sidecar's IP gets an `--add-host` entry for that name. The sidecar's `api.caddy` site is `http://:8080` (scoped by host matcher). It:

- applies `rewrite * {$API_PROXY_PREFIX}{uri}` to keep a gateway path prefix
- sets `header_up Host {upstream_hostport}`; unlike gh, the client hostname is not the upstream's
- runs `reverse_proxy {$API_PROXY_UPSTREAM}` with the upstream origin split off `ANTHROPIC_BASE_URL` on the host

Caddy flushes `text/event-stream` responses straight away, so SSE streaming needs no extra config.

- **Why not intercept the gateway's hostname** the way gh does:
  - The gateway hostname may also serve unrelated traffic the agent legitimately reaches.
  - Claude Code is the only client, and it already takes a base URL.
  - Interception would make the session CA a dependency of the model connection, which then breaks on any client-trust edge case. With a rewrite there is nothing new for Claude Code to trust.
- **Plain HTTP:** the hop runs on the session-private bridge network, which only the agent container and the sidecar are attached to. Prompts already sit in the agent's memory, and the credential never travels this hop.
- **Port 8080:** avoids Caddy's automatic HTTP→HTTPS redirect listener on `:80`, which exists whenever gh/glab TLS sites are present.

**Credential headers** are handled by two constant one-line snippets, staged according to which host variables are non-empty:

| Host variable | Set | Not set |
| --- | --- | --- |
| `ANTHROPIC_API_KEY` | `request_header x-api-key "{env.API_PROXY_KEY}"` | `request_header -x-api-key` |
| `ANTHROPIC_AUTH_TOKEN` | `request_header Authorization "{env.API_PROXY_BEARER}"` | `request_header -Authorization` |

This is what drops a claude.ai OAuth bearer from the persisted volume. Choosing between files keeps the config constant, and avoids depending on how Caddy treats an empty `{env.*}` value.

**Upstream trust:** when `CLAUDE_DOCKER_API_CA` is set, the sidecar mounts it. `transport http { tls_trust_pool file /etc/ssl/certs/ca-certificates.crt /etc/caddy/api-ca.pem }` then keeps the public roots and adds the private one. A pool holding only the private CA would break public-cert gateways for users whose CA exists for other reasons. Without the variable, the default transport is used.

### 7. Audit log redaction for the new sites

Caddy's access log records request headers. Clients only send placeholders, but `ANTHROPIC_CUSTOM_HEADERS` values do reach the sidecar. The glab and api site blocks therefore log through `format filter` with `request>headers delete`, and keep method, host, URI and status. The gh blocks are left alone, which keeps that capability's scope unchanged. No body is logged, which is already Caddy's default.

### 8. `-direct` escape hatches

`--glab-direct` and `--api-direct` set the same discovery and forwarding as today's `--glab` / `--api`, then skip the sidecar for that service. Other proxied services in the same session still use the sidecar. They:

- conflict with their proxied form in `validate_opts`
- appear as `glab-direct` / `api-direct` in `CLAUDE_DOCKER_FLAGS`
- share the existing masks: `/root/.config/glab-cli/` is unmasked under either glab flag

### 9. Test hooks

`CLAUDE_DOCKER_GLAB_UPSTREAM` (undocumented, tests only) repoints the GitLab upstream at a mock, mirroring `CLAUDE_DOCKER_GH_UPSTREAM`. The API needs no hook: the mock's URL is passed as `ANTHROPIC_BASE_URL`.

## Risks / Trade-offs

- **[Risk] glab config sets an `api_host` that differs from the host.** API calls go straight to that host carrying the placeholder, and get a `401`. → Document it, point to `--glab-direct`, and add a startup warning when the staged config's `api_host` for the proxied host differs from it.
- **[Risk] Claude Code's one-time custom-API-key approval appears again** because the key value changed to the placeholder. → The placeholder is constant, so it is approved once and remembered in the volume. Note it in `docs/auth.md`.
- **[Risk] The sidecar is now on the critical path for every model call.** If Caddy dies, the session is dead. → Caddy is stable under this load. Its logs are reachable through the printed name. Restarting the sidecar is deferred (see Open Questions).
- **[Trade-off] Plaintext between the agent and the sidecar** on a session-private bridge network. → No credential is on that hop, and no other container is attached.
- **[Risk] Short-lived glab OAuth tokens (about 2h) expire mid-session.** → Same as today's env forwarding; relaunch to refresh. Documented as unchanged.
- **[Risk] Private-CA self-hosted GitLab.** The sidecar trusts only public roots for upstreams. → This didn't work under `--glab` before either, and `--glab-direct` stays the route. A `CLAUDE_DOCKER_GLAB_CA` is a possible follow-up.
- **[Trade-off] `ANTHROPIC_CUSTOM_HEADERS` stays readable in the agent.** → The docs say plainly that only `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` are isolated.

## Migration Plan

- No user action is needed. Behaviour flips on upgrade for `--glab` and `--api`.
- Stray `claude-gh-*` resources from older versions are swept by the dual-prefix prune.
- **Rollback per user:** `--glab-direct` / `--api-direct`. **Rollback in the repo:** revert. No persisted state changes format.
- The `BREAKING` note in the release notes names both `-direct` flags.

## Open Questions

- Whether to start the sidecar with `--restart on-failure`. It would interact with the stopped-only prune and with diagnosing logs. Deferrable, and it changes no spec.
