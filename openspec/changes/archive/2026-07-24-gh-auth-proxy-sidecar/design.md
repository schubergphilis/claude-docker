# Design — GitHub Auth Proxy Sidecar

## Context

`run.sh --gh` forwards the host GitHub token into the agent container as `GH_TOKEN` (env passthrough, or `gh auth token` fallback). Anything running in the container — including a prompt-injected agent — can read it, and the fallback token is the host's long-lived, broad-scope gh OAuth credential. The README threat model documents this exposure; this change removes it.

Bearer-token auth has no ssh-agent-style delegation protocol: the secret travels in the `Authorization` header of every request, so the only way to keep it out of the agent container is to add the header *outside* it. That means a TLS-terminating proxy in the request path holding the token.

Constraints inherited from the repo: `run.sh` must stay bash-3.2-compatible, work under both docker and podman (`$RUNTIME`), work from git-bash on Windows (`hostpath()` translation), keep everything per-invocation with cleanup in the single EXIT trap, and require no manual setup steps beyond the existing `--gh` flag.

## Goals / Non-Goals

**Goals:**
- The real GitHub token never exists inside the agent container — not in env, not on its filesystem, not retrievable via `gh auth token`.
- `gh` and `git` (HTTPS remotes) work unchanged inside the container; no new user steps versus today's `--gh`.
- Multiple concurrent sessions, each fully isolated (own network, sidecar, CA, token copy).
- Lightweight: one pinned upstream Caddy image, no custom image build, sidecar idles in tens of MB.
- A policy point in the sidecar: default rule blocks repo deletion; user-extensible; every proxied request logged.

**Non-Goals:**
- Self-hosted / custom-hostname GitHub — GitHub Enterprise **Server** (`github.mycompany.com`) and GHEC data residency (`*.ghe.com`). Organizations on github.com, including those under a GitHub Enterprise **Cloud** account, use the standard hostnames and are fully in scope. Custom-hostname users keep `--gh-direct`; today's `--gh` never supported them either.
- Equivalent proxies for other credential flags — this change is intentionally the GitHub-only PoC of the pattern. Roadmap (each a future change): **Terraform Cloud** and **GitLab** are near-1:1 ports (bearer token, single hostname — reuse the injection sidecar as-is); **AWS** needs separate research because SigV4 request signing rules out static header injection — evaluate a re-signing sidecar (awslabs/aws-sigv4-proxy + dummy-credential placeholder + `AWS_ENDPOINT_URL` redirection, which replaces DNS interception and possibly the CA) against vending short-lived scoped STS credentials via the ECS container-credentials protocol. The session-lifecycle/teardown/policy/audit chassis from this change is the reusable part in all cases.
- Egress filtering of non-GitHub traffic.
- Persisting audit logs beyond the session.
- Hiding the *capability* while the session runs — a compromised session can still act via the proxy, within policy. The design removes the exfiltratable secret and adds guardrails, not the live capability.

## Decisions

### Decision: Caddy as the sidecar proxy (over mitmproxy, privoxy, hand-rolled)

Caddy is a single static binary with a built-in local CA (`tls internal`) that auto-generates the root at first start, mints and rotates short-lived leaf certs per hostname (covers week-long sessions), and drops the public root at a well-known path (`/data/caddy/pki/authorities/local/root.crt`). SNI routing, header replacement, method/path matchers, and JSON access logs are all first-class Caddyfile directives — the entire security-relevant config is one reviewable generated file. mitmproxy offers a more powerful (Python) policy engine at the cost of a far larger image and attack surface; privoxy is a forward filtering proxy and cannot act as a certificate-presenting reverse proxy. If policy ever outgrows matchers, the sidecar can be swapped for mitmproxy without changing the architecture.

### Decision: Redirect via `--add-host` on the agent container, not `--network-alias` on the sidecar

A network alias resolves network-wide — including for the sidecar itself, which would then dial its own IP when forwarding upstream (loop). `--add-host github.com:<sidecar-ip>` (and the other two hostnames) rewrites resolution only inside the agent container via `/etc/hosts`: git and curl follow it through libc `getaddrinfo`, and `gh` — a Go binary with its own resolver — follows it too because Go's pure resolver also consults `/etc/hosts` (asserted explicitly by the integration harness rather than assumed). The sidecar resolves GitHub normally. Sequencing: create network → start sidecar → `$RUNTIME inspect` its IP on that network → pass `--add-host` entries to the agent container. Works identically under podman.

### Decision: Intercepted hostname set is exactly `github.com`, `api.github.com`, `uploads.github.com`

These are the hosts that require the `Authorization` header (git smart-HTTP, REST/GraphQL API, release-asset upload). Redirect targets like `objects.githubusercontent.com` and `codeload.github.com` serve pre-signed URLs that need no auth — they resolve normally and never see the token, which also keeps the header from leaking to hosts that shouldn't receive it.

### Decision: Header forms per hostname, token only in sidecar env

- `api.github.com`, `uploads.github.com`: `Authorization: Bearer <token>`
- `github.com` (git smart-HTTP): `Authorization: Basic base64("x-access-token:<token>")`

`run.sh` computes both values on the host and passes them to the sidecar as env vars — each holding the **complete header value including the scheme prefix** (`GH_PROXY_BEARER="Bearer <token>"`, `GH_PROXY_BASIC="Basic <b64>"`), so the Caddyfile can inject them verbatim. The base64 encoding is piped through `tr -d '\n'`: GNU base64 wraps at 76 characters (which the encoded credential exceeds) while BSD's does not. The generated Caddyfile references `{env.*}` placeholders, so the staged Caddyfile on the host disk never contains the token. `header_up Authorization` *replaces* any client-supplied value, so whatever the agent sends is discarded.

### Decision: Placeholder `GH_TOKEN` in the agent container

`gh` refuses API commands when it believes it is unauthenticated, so the agent container gets `GH_TOKEN=claude-docker-proxy`. `gh` sends it; the sidecar strips and replaces it. `gh auth token` inside the container returns the worthless placeholder — the headline property of this change. Because the env var also outranks `~/.config/gh/hosts.yml`, the `/root/.config/gh` tmpfs mask stays ON while the sidecar is active (in-container `gh auth login` state is unnecessary and would reintroduce a persisted secret). The unmask survives only in the no-token fallback and under `--gh-direct`.

### Decision: Ephemeral per-session CA, distributed via stage dir + entrypoint

The sidecar container is ephemeral (`--rm`, no volume), so Caddy generates a fresh root CA every session; the private key never leaves the sidecar and dies with it. After starting the sidecar, `run.sh` retry-loops `$RUNTIME cp <sidecar>:/data/caddy/pki/authorities/local/root.crt` into the existing stage dir (timeout ~15s → teardown + clear error), then bind-mounts it read-only at `/usr/local/share/ca-certificates/claude-docker-gh-proxy.crt`. `entrypoint.sh` runs `update-ca-certificates` when that file is present — it still runs as root at that point, before the UID drop. `NODE_EXTRA_CA_CERTS` is set to the same path so node-based tooling trusts it too. git (libcurl) and gh (Go) read the system store natively.

This sequencing assumes Caddy materializes the local PKI **at config load**, not lazily on the first TLS handshake — if it were lazy, the CA wait-loop would deadlock (the only TLS client starts after it) and every session would hit the fail-closed path. **Verified empirically (2026-07-24) against the pinned image (`caddy:2.11.4@sha256:844f60b6…`) on a real docker host:** root + intermediate CA exist at startup with zero client traffic; the leaf certs for all three hostnames are also minted eagerly at config load by the internal issuer (`tls.obtain` log lines — internal issuance, not ACME); no ACME/challenge activity is emitted. The wait-loop design holds with no warm-up request.

### Decision: Per-invocation network + sidecar, names derived from the stage dir suffix

Reuse the `mktemp` suffix from the existing stage dir (`host.XXXXXX`) as the session id: network `claude-gh-<id>`, sidecar `claude-gh-proxy-<id>`. Uniqueness comes for free from `mktemp`; concurrent sessions cannot collide or cross-talk (distinct networks, distinct sidecars, distinct CAs). Teardown extends the existing EXIT trap — and the extended trap is installed **before** any network or sidecar is created: `rm -f` / `network rm` tolerate not-yet-existing resources, so trap-then-create closes the window where a `set -e` failure between resource creation and a later re-trap would leak a container + network. The startup prune of stale `claude-gh-*` resources is a backstop for hard kills, not the primary cleanup. `run.sh` prints the sidecar container name at startup so users can find the audit log stream (`$RUNTIME logs claude-gh-proxy-<id>`).

### Decision: Pinned image, no custom build, silent skip without a token

The sidecar runs the official Caddy image pinned by digest, recorded in `run.sh` as a default overridable via `CLAUDE_DOCKER_PROXY_IMAGE` (`run.sh` cannot read `pins/` — it must work standalone). First `--gh` run pulls the image implicitly. Token acquisition is unchanged (env, else `gh auth token`, else nothing); when no token is found, the sidecar is skipped entirely and the session behaves like today's silent no-token fallback — no proxy, no placeholder, unmasked `gh` config so in-container `gh auth login` remains possible. If the sidecar fails to start or the CA never appears, `run.sh` tears down and exits with a clear error rather than silently degrading to direct token forwarding.

### Decision: Filtering as Caddy matchers; default blocks repo deletion; user snippet extension

The generated Caddyfile's `api.github.com` block includes a named matcher for `DELETE` on `^/repos/[^/]+/[^/]+/?$` (repo deletion — destructive, never needed by an agent) answered with `403` and a body identifying the claude-docker policy. Everything else passes. Users extend policy by pointing `CLAUDE_DOCKER_GH_POLICY` at a Caddyfile snippet that `run.sh` stages and `import`s into the site blocks. Policy lives only in the sidecar, whose config and env the agent container cannot reach.

### Decision: Audit logging to sidecar stdout, deliberately not persisted

Caddy's JSON access log (method, path, status, no auth headers) goes to stdout, viewable live via `$RUNTIME logs claude-gh-proxy-<id>` — the name is printed at session start so the stream is discoverable. Non-persistence is a decision, not a gap: host-side `gh` usage has no audit log today either, so the session-scoped stdout log is already a strict improvement, and its primary purpose is live debugging of proxy behavior. Because the sidecar runs `--rm`, the log vanishes at teardown; persisting it can be added later if a need appears.

### Decision: `--gh-direct` escape hatch

Restores the exact legacy behavior (token env-forwarded into the agent container, gh config unmask). Needed for custom-hostname GitHub (Enterprise Server / `*.ghe.com`), air-gapped hosts that can't pull the Caddy image, and as a rollback path. Mutually exclusive with the proxy: passing `--gh` and `--gh-direct` together is rejected with an error (matching the existing unknown-flag exit style) rather than silently picking one. `--gh-direct` surfaces as its own `gh-direct` entry in the `CLAUDE_DOCKER_FLAGS` statusline tag so the riskier mode is visibly distinct from proxied `gh`.

### Decision: Verification via a run.sh-driven harness with a mock upstream, plus a manual checklist

The existing `smoke/smoke.sh` reconstructs `docker run` itself and never invokes `run.sh` — but the entire sidecar lifecycle lives in `run.sh`, and CI has no GitHub credentials. So verification splits: a new integration harness (under `tests/`) drives `run.sh` end-to-end against a **mock GitHub upstream** container, enabled by a test-only upstream-override hook in the Caddyfile generation — this covers CA trust, placeholder isolation, header injection, policy blocks, audit logging, concurrent-session isolation, and teardown, all credential-free and CI-runnable. Assertions that need real credentials (live `gh api /user`, private clone/push, git-LFS) go to the README's existing manual checklist.

### Decision: The Caddy image pin is manual, excluded from update_pins.py

A proxy upgrade is not a routine version bump: a new Caddy release can change Caddyfile directive semantics — i.e. our security-critical automation — so upgrading (e.g. for a CVE) requires reading the changelog and validating the generated config against the new version, by a developer or an agent acting for one. Automating the bump would produce false confidence in exactly the component that must not silently drift. The pin therefore lives in `run.sh` as a manual, reviewed change, deliberately outside `update_pins.py`.

## Risks / Trade-offs

- [TLS clients that ignore the system store (Python `certifi`, some Java) fail against intercepted hostnames] → Documented limitation; git/gh/node (via `NODE_EXTRA_CA_CERTS`) — the actual GitHub consumers in the image — all use covered stores. Workaround for others: standard `SSL_CERT_FILE`-style overrides, or `--gh-direct`.
- [Agent trusts a session CA that could theoretically MITM anything] → The CA only sits in the path of the three `--add-host`ed hostnames; all other names resolve past the sidecar. The CA is also ours, generated fresh per session, and its key is destroyed at teardown.
- [SSH remotes (`git@github.com`) resolve to the sidecar and fail fast on port 22] → SSH was never supported in-container (no keys/agent mounted); failure mode changes from auth-failure to connection-refused. Documented.
- [Caddy image pull needed on first `--gh` run] → One-time, small image; failure surfaces a clear error and `--gh-direct` remains available.
- [`gh auth status` / rate-limit output reflects the real host identity] → Intended: proves injection works; the token itself stays unreadable.
- [Sidecar adds per-session containers/networks that could leak on `kill -9` of run.sh] → EXIT trap covers normal paths; names are prefixed (`claude-gh-`) so stragglers are identifiable; a best-effort prune of stale resources at next startup is cheap insurance (implementation detail).
- [Docker Desktop vs podman `inspect` format drift for the sidecar IP] → Use `--format` templates verified against both runtimes in smoke tests; podman ≥4 matches docker's network inspect layout.
- [Blocked-by-policy responses could confuse the agent] → 403 body names the policy and the flag to adjust, so the agent/user gets an actionable message rather than a mystery GitHub error.

## Migration Plan

1. Land sidecar + `--gh` rewire + `--gh-direct` in one change; `--gh` UX is unchanged for the happy path.
2. README: update credential opt-in table, threat model (token no longer exfiltratable; capability + policy note), new proxy section with limitations.
3. Verification per the harness decision: CI-runnable `run.sh`-driven integration tests against the mock upstream; real-credential assertions added to the README manual checklist.
4. Rollback: users pass `--gh-direct` (or pin to a prior release); no persistent state to migrate either way.

## Open Questions

None remaining. The two questions raised during drafting were resolved into decisions above: the Caddy pin stays manual and outside `update_pins.py` (proxy upgrades are reviewed changes, not automated bumps), and sidecar audit logs are deliberately stdout-only, not persisted (see the audit-logging decision for rationale).
