## Context

The `gh-auth-proxy` sidecar injects `Authorization` on **every** request to the three intercepted hostnames. For `github.com` that is `Basic base64(x-access-token:<token>)`, chosen because git smart-HTTP needs it. But `github.com` is not only the git transport — it also serves web endpoints, and the release-download path is one of them.

Two things about that path were unknown when the sidecar was designed, and both were measured for this change rather than assumed:

1. GitHub picks the CDN for a release asset based on **whether an `Authorization` header is present**. Anonymous requests get `release-assets.githubusercontent.com` (current, JWT-signed). Requests carrying a credential get `objects.githubusercontent.com` (legacy S3 pre-signed) — and that legacy URL now answers `401` to every method, including a ranged `GET`, seconds after being issued. It is dead infrastructure that GitHub still hands out.

2. That endpoint **does not accept token auth at all**. The web download path wants a browser session. So the credential the sidecar injects there is inert: it cannot unlock a private asset, and its only observable effect is selecting the dead CDN.

The interaction only bites clients that probe with `HEAD` first. `curl -fsSL` goes straight to `GET`, gets the working CDN, and never notices — which is why the sidecar shipped with this latent for months and why the issue looked like a `uv` bug.

### Evidence

All measured from inside a live `--gh` session on `uv` 0.11.29 / `aarch64`, against real GitHub. The credential-presence tests used a *bogus* token sent directly to `github.com` via `--resolve`, which reproduces the routing exactly — proving the trigger is the header's presence, not its identity, and letting the A/B run without a real token on the wire.

| # | Observation |
|---|---|
| 1 | `HEAD` + any `Authorization` → `objects.githubusercontent.com`; `GET` + any `Authorization`, and both methods anonymous → `release-assets.githubusercontent.com`. The conjunction is the trigger. |
| 2 | The `objects.*` URL returns `401` with an empty body to `GET` and to a ranged `GET`, not just to `HEAD`. Not a "pre-signed for GET only" artifact. |
| 3 | `X-Forwarded-For`/`-Proto`/`-Host` do **not** trigger it, so Caddy's forwarding headers are not implicated. |
| 4 | Private repo (two of them), real token injected by the live sidecar: the web `/releases/download/` URL returns `404` for **both** `HEAD` and `GET`. The same token fetches the same asset with `206` via `GET /repos/{o}/{r}/releases/assets/{id}` (`Accept: application/octet-stream`), and `gh release download` retrieves it whole. The credential is valid; the endpoint just doesn't honour it. |
| 5 | `git ls-remote` against a private repo through the same sidecar succeeds — the injected `Basic` header is well-formed and honoured where it matters, so #4 is not a malformed-header artifact. |
| 6 | Only `/releases/download/` is auth-sensitive. `/archive/refs/tags/*` (→ `codeload`), `/raw/<ref>/<path>` (→ `raw.githubusercontent.com`) and `/releases/latest/download/*` redirect identically with and without a credential. |
| 7 | End-to-end, driving real `uvx` through the *generated* Caddyfile from `git HEAD` vs. the working tree, both with a credential injected: pre-fix fails with the exact `401` from the issue, post-fix installs the 12.8 MB wheel. |

## Goals / Non-Goals

**Goals:**

- `uv`/`uvx` install from a public `github.com` release-asset URL inside `--gh`, no flags, no env overrides.
- Zero change to any request that works today — in particular every request that carries the credential today still carries it.
- Keep full TLS verification. No `UV_INSECURE_HOST`, no `tls_insecure_skip_verify`.
- Fix belongs in `run.sh`, so no image rebuild is needed.

**Non-Goals:**

- Making private release-asset *web* URLs work. GitHub doesn't support it; the API asset endpoint is the supported route and already works through the sidecar.
- A general "inject credentials only on git-transport paths" redesign of the `github.com` block. Tempting, and probably right eventually, but it is a redesign with real LFS/web-path regression surface — not a bug fix.
- Fixing every private-root-store TLS client. `uv` is the one shipped tool with the blind spot; the general `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` escape hatch stays documented for anything the user brings.

## Decisions

### Drop the header on `HEAD`, rather than rewriting the method

Two candidates fix defect 2. Both were implemented and measured.

**A — drop `Authorization` for `HEAD` on the release-download path** (chosen). The probe takes the same anonymous route `curl` already takes successfully.

**B — rewrite `HEAD`→`GET` upstream via Caddy's `method` directive, keeping the credential.** Also works. Verified protocol-correct: two pipelined `HEAD`s over one keep-alive connection each came back a clean `302` with zero body bytes, so Go's server does suppress the body despite the handler having mutated `r.Method`. Real `uvx` installed through it.

B's only advantage would be preserving an authenticated `HEAD` capability — which evidence #4 shows this endpoint does not offer. Against that it costs: the access log records `HEAD` while GitHub receives `GET` (an audit-fidelity gap in a component whose logging is a spec requirement); an upstream `GET` for every probe; observed loss of the upstream `Content-Length` on the synthesized `HEAD` response; and a semantic change a reader of the config would not expect from a transparent proxy. A is the smaller, more legible change and strictly *reduces* the number of paths the host token travels on. Chose A.

### Scope by method **and** path, not by path alone

Dropping the credential for the whole `/releases/download/` prefix (any method) is defensible on the same evidence — it would restore byte-identical un-proxied behavior and is simpler to express. Rejected anyway: authenticated `GET` on that path works today, and evidence #4 covers only OAuth/PAT tokens. If a GitHub App installation token (whose git convention is exactly the `x-access-token:` username the sidecar uses) is ever honoured on that endpoint, a `GET`-inclusive exclusion would silently remove access, while the `HEAD`-only form cannot: it touches only requests that return an unusable `401` for every caller today. That makes "no regressions" a structural property rather than a claim resting on the token types available to test.

### Delete the header, don't just skip injection

`handle` blocks that omit `header_up Authorization` would forward whatever the client sent — and the agent container's `gh`/`git` send the placeholder `GH_TOKEN=claude-docker-proxy`. Since *any* `Authorization` value selects the dead CDN (evidence #1, established with a bogus token), skipping injection would leave the bug in place for exactly the clients that matter. `header_up -Authorization` deletes it. This also keeps the existing spec property that the placeholder never reaches GitHub.

### `UV_SYSTEM_CERTS=1`, sidecar-scoped

Four env-only workarounds clear defect 1. `UV_INSECURE_HOST` is out — it disables verification. `SSL_CERT_FILE` works but is process-wide and would redirect every OpenSSL consumer in the container, which deserves its own decision rather than riding along in a bug fix. That leaves the `uv`-specific pair: `UV_NATIVE_TLS` is deprecated in the pinned `uv` and prints a warning on every invocation, so `UV_SYSTEM_CERTS` it is. Confirmed bound (`[env: UV_SYSTEM_CERTS=]`) and working end-to-end in **0.11.21**, the currently committed pin, as well as 0.11.29 — so the fix does not depend on the pending pin bump.

Set alongside `NODE_EXTRA_CA_CERTS`, i.e. only when the sidecar is active: with no interception there is no session CA and nothing extra to trust. `--gh-direct` and the no-token fallback are untouched.

### Matcher shape

`^/[^/]+/[^/]+/releases/download/.+` on `method HEAD`. The trailing `.+` requires an asset segment, so a bare `/o/r/releases/download/` keeps its credential. `/releases/latest/download/<asset>` is *not* matched directly and does not need to be — its first hop is a `302` to the canonical `/releases/download/<tag>/<asset>` URL (identical with and without a credential), and that second hop comes back through the sidecar and is matched.

Ordering uses two `handle` blocks rather than a bare matcher on a single `reverse_proxy`, because the two branches need different `header_up` treatment. `handle` is mutually exclusive, so the general branch is a plain `handle` fallback.

## Risks / Trade-offs

- **[A tool probes a release asset in a private repo]** → gets `404` instead of today's `401`-after-redirect. Both are failures; neither is reachable. Documented with the `gh release download` alternative.
- **[The exclusion widens past `HEAD` in a later edit]** → would remove the credential from authenticated `GET`s that work today. Guarded by a paired assertion in the integration harness: `HEAD` must arrive with no `Authorization`, `GET` on the same path must arrive with `Basic`.
- **[GitHub changes release-asset routing again]** → the fix becomes unnecessary but stays harmless: an anonymous `HEAD` on a public asset is the same request `curl` makes. The failure mode is not a regression, just a dead branch.
- **[`UV_SYSTEM_CERTS` is only correct if the CA install succeeded]** → if the entrypoint's `update-ca-certificates` didn't run (issue #11's skew scenario), `uv` points at a bundle with no Caddy root and the error changes rather than disappears. The two issues compose; this is not a substitute for #11.
- **[Anonymous release-asset probes are rate-limited differently]** → not observed; the bytes come from a pre-signed CDN URL either way, and the `GET` that transfers them is unchanged.

## Migration Plan

None. No state, no flags, no image layer. Existing sessions are unaffected; the next `claude-docker --gh` launch regenerates the Caddyfile and the env with the fix in place.

## Open Questions

- Should the `github.com` block eventually inject credentials **only** on git-transport and LFS paths, leaving all web paths anonymous? That is the principled end state and would have prevented this bug by construction. Deferred — it needs its own change with LFS coverage.
- Does any GitHub App installation token get honoured on the web release-download endpoint? Untestable with the credentials available here. The `HEAD`-only scope means the answer doesn't change this fix's correctness either way.
