## 1. Scope the defect before choosing a fix

- [x] 1.1 Reproduce both failures inside a live `--gh` session (`uv` 0.11.29, `aarch64`)
- [x] 1.2 A/B method against credential presence directly against `github.com` (via `--resolve`, bogus token) to isolate the trigger as `HEAD` + any `Authorization` — ruling out the method alone, the credential alone, and `X-Forwarded-*`
- [x] 1.3 Confirm the legacy `objects.githubusercontent.com` URL is dead for every method, not pre-signed for `GET` only
- [x] 1.4 Establish whether the injected credential grants anything on this endpoint: two private repos, real token, web `/releases/download/` URL → `404` for both `HEAD` and `GET`, while the API asset endpoint returns `206` and `gh release download` succeeds
- [x] 1.5 Confirm the injected `Basic` header is well-formed and honoured where it matters (`git ls-remote` against a private repo through the sidecar)
- [x] 1.6 Map which other `github.com` paths are auth-sensitive (`/archive/`, `/raw/`, `/releases/latest/download/`, git smart-HTTP — none are)

## 2. Fix the TLS failure in `run.sh`

- [x] 2.1 Add `-e UV_SYSTEM_CERTS=1` to `ENV_ARGS` next to `NODE_EXTRA_CA_CERTS`, inside the sidecar-active branch only
- [x] 2.2 Verify the variable is honoured by the **committed** pin (`uv` 0.11.21), not just the pending bump — `[env: UV_SYSTEM_CERTS=]` in `--help` plus an end-to-end install through the intercepted `github.com`
- [x] 2.3 Prefer `UV_SYSTEM_CERTS` over the deprecated `UV_NATIVE_TLS` (which warns on every invocation); reject `UV_INSECURE_HOST` (disables verification) and process-wide `SSL_CERT_FILE`
- [x] 2.4 Comment the block with the three-trust-store rationale and why it is sidecar-scoped

## 3. Fix the 401 in the generated sidecar Caddyfile

- [x] 3.1 Add a `@gh_release_asset_head` matcher (`method HEAD` + `path_regexp ^/[^/]+/[^/]+/releases/download/.+`) to the `github.com` site block
- [x] 3.2 Split into two `handle` blocks: the matched branch forwards with `header_up -Authorization`, the fallback keeps `header_up Authorization "{env.GH_PROXY_BASIC}"`
- [x] 3.3 Delete rather than omit the header, so the placeholder `GH_TOKEN` that `gh`/`git` send cannot trigger the same routing
- [x] 3.4 Comment the block with the GitHub-side routing behaviour, why the credential is inert here, and why the scope is method+path
- [x] 3.5 Update the generator's header comment, which claimed `Authorization` is always *replaced*

## 4. Verify against the real generated artifact

- [x] 4.1 Extract `gen_gh_proxy_caddyfile()`'s heredoc verbatim, run it on the pinned Caddy 2.11.4 against a header-echoing mock, and assert the credential carried by 18 method+path combinations (release-asset `HEAD`/`GET` with and without the client placeholder, `releases/latest/download`, git smart-HTTP `info/refs` + `git-upload-pack`, LFS batch, `/archive/`, `/raw/`, repo page, releases page, nested asset path, bare `/releases/download/`, and all three hosts) — all pass
- [x] 4.2 Before/after end-to-end: build the sidecar config from `git HEAD` and from the working tree, inject a credential, drive real `uvx` through each against real `github.com` — pre-fix reproduces the issue's exact `401`, post-fix installs the wheel
- [x] 4.3 Confirm `bash -n` clean on `run.sh` and the harness
- [x] 4.4 Run `tests/gh-proxy-integration.sh` on a host with docker (not available in-container) — `PASS=50 FAIL=0 SKIP=0`, including all four new `#22` assertions, alongside a live `--gh` session
- [x] 4.5 Validate on a live restarted session: `UV_SYSTEM_CERTS=1` in the env, release-asset `HEAD` (with and without a client placeholder) redirecting to `release-assets.githubusercontent.com`, `HEAD -L` → `200`, and the issue's exact `uvx` reproducer succeeding with no flags
- [x] 4.6 Validate the real-world composite case: `uvx --python 3.13 --from "zeppelin[…] @ git+https://github.com/gmtdi/zeppelin@main" --with <public release-asset wheel>` — private-repo git resolution, a 382 MiB public release asset, and a cold managed-CPython fetch from `python-build-standalone` release assets all succeed

## 5. Regression guards in `tests/gh-proxy-integration.sh`

- [x] 5.1 Assert `UV_SYSTEM_CERTS=1` is present in the agent container's environment
- [x] 5.2 Issue a `HEAD` and a `GET` to a release-asset path on `github.com` from inside the container
- [x] 5.3 Assert in-container that the `GET` still carries the injected `Basic` credential (mock echoes it in the body)
- [x] 5.4 Assert host-side from the mock's access log that the `HEAD` arrived with **no** `Authorization` header, and that the `GET` on the same path arrived **with** `Basic` — the paired guard against the exclusion widening past `HEAD`
- [x] 5.5 Extend the harness's assertion→task mapping header, and note that GitHub-side redirect routing cannot be asserted against a mock

## 6. Documentation

- [x] 6.1 README: document `UV_SYSTEM_CERTS=1` alongside `NODE_EXTRA_CA_CERTS`, naming the rustls blind spot
- [x] 6.2 README: document the `HEAD` exception in the credential-injection bullet, with the GitHub routing reason
- [x] 6.3 README: add the private-release-asset limitation and its supported workaround (`gh release download` / API asset endpoint)
- [x] 6.4 README: extend the existing trust-store limitation with the `SSL_CERT_FILE` / `REQUESTS_CA_BUNDLE` escape hatch for other clients

## 7. Spec delta

- [x] 7.1 `MODIFIED` *GitHub token is isolated from the agent container* — carry the scoped `HEAD` exception into the replace-the-`Authorization`-header clause, keeping both existing scenarios
- [x] 7.2 Add a scenario pinning the method-scoped behaviour (`HEAD` anonymous, `GET` still credentialed)
- [x] 7.3 `MODIFIED` *GitHub traffic is redirected through the sidecar with a per-session CA* — extend trust distribution to `UV_SYSTEM_CERTS`, keeping both existing scenarios
- [x] 7.4 Add a scenario for a private-root-store client trusting the session CA
- [x] 7.5 `openspec validate fix-gh-proxy-release-asset-probes --strict` passes
