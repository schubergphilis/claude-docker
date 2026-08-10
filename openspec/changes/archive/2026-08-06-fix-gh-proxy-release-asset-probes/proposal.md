## Why

Inside a `--gh` session, `uv`/`uvx` cannot fetch anything from `github.com` ([#22](https://github.com/schubergphilis/claude-docker/issues/22)). Two independent defects stack:

1. **TLS.** `uv`'s HTTPS client is rustls with a bundled webpki root store. It reads neither the OS trust store (where the entrypoint installs the session CA) nor `NODE_EXTRA_CA_CERTS`, so every request to an intercepted hostname dies with `invalid peer certificate: UnknownIssuer` — while `git`, `gh` and `curl` on the same URL succeed. This is a third trust-store family the proxy never accounted for: OS bundle (Go/OpenSSL tools), `NODE_EXTRA_CA_CERTS` (node), and *neither* (rustls).

2. **HTTP 401 on public release assets.** With TLS resolved, installing from a `https://github.com/<owner>/<repo>/releases/download/…` URL fails `401 Unauthorized`, even though `curl` on the identical URL through the same sidecar downloads it fine.

Defect 2's trigger was isolated by A/B-ing method against credential directly against `github.com`:

| request | redirects to | usable |
|---|---|---|
| `HEAD`, no `Authorization` | `release-assets.githubusercontent.com` | yes |
| `GET`, no `Authorization` | `release-assets.githubusercontent.com` | yes |
| `GET`, any `Authorization` | `release-assets.githubusercontent.com` | yes |
| **`HEAD`, any `Authorization`** | **`objects.githubusercontent.com`** | **no — 401 to every method** |

So it is the *conjunction* of `HEAD` and a credential. Any `Authorization` value triggers it — a bogus token reproduces it exactly, so this is GitHub routing on the header's presence, not on the identity it carries. `uv` probes with `HEAD` before `GET`, so it lands squarely in the broken cell; `curl -fsSL` never issues a `HEAD` and never sees it. The proxy injects `Authorization` on every `github.com` request (git smart-HTTP needs it), which is what puts `uv` there. Neither `X-Forwarded-*` nor Caddy's `HEAD` handling is involved — both were ruled out by direct test.

The injected credential also turns out to buy *nothing* on this endpoint: `github.com`'s web release-download path accepts only browser-session auth. Verified against two private repos whose assets the same token can read fine via the API — the web URL returns `404` for **both** `HEAD` and `GET` with the real token injected. Private release assets were therefore never reachable this way, with or without the proxy; there is no authenticated capability on this path to preserve.

## What Changes

- **`run.sh` — generated sidecar Caddyfile.** In the `github.com` site block, add a `method HEAD` + `path_regexp ^/[^/]+/[^/]+/releases/download/.+` matcher whose `handle` forwards with `header_up -Authorization`; all other traffic keeps the existing `header_up Authorization "{env.GH_PROXY_BASIC}"` injection. The header is **deleted, not merely un-injected**: `gh`/`git` send the placeholder `GH_TOKEN`, and *any* `Authorization` value triggers the same legacy routing.
- **`run.sh` — agent container env.** Add `-e UV_SYSTEM_CERTS=1` next to the existing `NODE_EXTRA_CA_CERTS`, so `uv` reads the OS trust store and validates against the session root. Set only when the sidecar is active, mirroring `NODE_EXTRA_CA_CERTS`. Certificate verification is preserved — this is not `UV_INSECURE_HOST`. (`UV_SYSTEM_CERTS` over the deprecated `UV_NATIVE_TLS`; both are honoured by the pinned `uv`, only the newer one is warning-free.)
- **`tests/gh-proxy-integration.sh`.** Assert `UV_SYSTEM_CERTS=1` in the agent env; assert from the mock's access log that the release-asset `HEAD` arrives with **no** `Authorization` while the `GET` on the same path still arrives **with** the injected `Basic` header (the regression guard against the exclusion widening past `HEAD`).
- **README.** Document `UV_SYSTEM_CERTS`, the `HEAD` exception and why it exists, and add the private-release-asset limitation with its supported workaround (`gh release download`).
- **`gh-auth-proxy` spec.** Modify two requirements (details under Capabilities).

Deliberately *not* done: rewriting `HEAD`→`GET` upstream (Caddy's `method` directive). It was built and tested — it works, is protocol-correct, and would keep the credential on the wire — but its only advantage over dropping the header is preserving an authenticated capability this endpoint does not offer. It costs an audit-log fidelity mismatch (the log records `HEAD`, GitHub receives `GET`) and an upstream `GET` for every probe. Dropping the header is the smaller, more transparent change.

## Capabilities

### New Capabilities

*(none — this change modifies an existing capability)*

### Modified Capabilities

- `gh-auth-proxy`: two requirements change.
  - *GitHub token is isolated from the agent container* — currently states without qualification that the sidecar "SHALL replace any client-supplied `Authorization` header with the real one". Gains a single scoped exception: on `github.com`, a `HEAD` to `/<owner>/<repo>/releases/download/…` is forwarded with the header **removed**. The isolation guarantee itself is unchanged and, if anything, strengthened: one more request class where the host token never goes on the wire.
  - *GitHub traffic is redirected through the sidecar with a per-session CA* — the trust-distribution clause currently names only `NODE_EXTRA_CA_CERTS`. Extended to also require `UV_SYSTEM_CERTS=1`, and to state the general property that clients with a private root store need an explicit pointer at the session CA.

## Impact

- **Code**: `run.sh` (a matcher + two `handle` blocks in the generated Caddyfile; one `ENV_ARGS` entry), `tests/gh-proxy-integration.sh` (four assertions), `README.md`.
- **Spec**: `openspec/specs/gh-auth-proxy/spec.md` — two modified requirements.
- **User-facing**: `uv`/`uvx` install from public GitHub release-asset URLs with no flags and no env overrides. Private release-asset URLs still fail (unchanged, GitHub-side) but are now documented with a working alternative.
- **No rebuild required.** Both halves are emitted by `run.sh` at container start, so relaunching an existing image picks them up. No Dockerfile change, no new capability, no new container surface.
- **Regression surface**: exactly one request class changes — `HEAD` on `github.com/<owner>/<repo>/releases/download/…`, which returns an unusable `401` for every caller today. Every request that works today keeps its credential and its route: authenticated `GET` on the same path (verified unchanged), git smart-HTTP, git-LFS batch, `/archive/`, `/raw/`, and both `Bearer` hosts. `/releases/latest/download/<asset>` is covered transitively — its first hop redirects to the canonical `/releases/download/<tag>/<asset>` URL, which is matched.
