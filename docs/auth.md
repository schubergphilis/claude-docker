# Auth model

[← Back to the README](../README.md)

Credentials are opt-in per run — see [Credential opt-in](../README.md#credential-opt-in) for the per-flag effect, mounts, and env-var forwarding. The subsections below cover the two workflows that need more than a one-line table cell.

## AWS SSO flow (`--aws`)

Standard SSO usage works unchanged: `aws sso login --profile X && export AWS_PROFILE=X` on the host, then `claude-docker --aws`. The container reads the short-lived SSO bearer token from `~/.aws/sso/cache` via the read-only mount.

If you'd rather not mount `sso/cache` either, flatten to env vars after login:

```bash
aws sso login --profile X
eval "$(aws configure export-credentials --profile X --format env)"
claude-docker --aws ...
```

Container then uses `AWS_ACCESS_KEY_ID`/`SECRET`/`SESSION_TOKEN` and the SSO cache is not needed inside. Temp creds freeze at container start (~1h TTL).

## GitHub auth proxy

`--gh` starts a per-session **auth proxy sidecar** (pinned Caddy image `caddy:2.11.4@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9`, override via `CLAUDE_DOCKER_PROXY_IMAGE`) that holds the real GitHub token so the agent container never sees it. Token discovery is unchanged: `GH_TOKEN` / `GITHUB_TOKEN`, else host `gh auth token`, else a silent skip — no token found means no sidecar, and the session behaves like the legacy no-token fallback (empty `GH_TOKEN`, in-container `gh auth login` still works and persists as before).

When a token is found:

- The agent container gets a placeholder `GH_TOKEN=claude-docker-proxy` — enough for `gh` to consider itself authenticated. `gh auth token` inside the container returns this placeholder, not your real token, and it doesn't appear anywhere in the container's environment or filesystem.
- `github.com`, `api.github.com`, and `uploads.github.com` resolve to the sidecar via `--add-host`. `objects.githubusercontent.com` and `codeload.github.com` (pre-signed release/archive URLs) are **not** intercepted — they resolve normally and never see the token.
- The sidecar terminates TLS for those three hostnames with a CA generated fresh for the session; the private key never leaves the sidecar and is destroyed with it at teardown. The public root is installed into the agent container's trust store by the entrypoint (`update-ca-certificates`, before privilege drop), and `NODE_EXTRA_CA_CERTS` points at it, so `git`, `gh`, and node-based tooling all trust it natively. `UV_SYSTEM_CERTS=1` is set for the same reason: `uv`'s rustls client reads neither the OS bundle nor `NODE_EXTRA_CA_CERTS` by default, so without it every `uv` fetch from `github.com` fails `invalid peer certificate: UnknownIssuer` while `git`/`gh`/`curl` work. Verification stays on — `uv` just checks against the same session root.
- The sidecar injects the real `Authorization` header in transit — `Basic base64(x-access-token:<token>)` for `github.com` (git smart-HTTP), `Bearer <token>` for `api.github.com` / `uploads.github.com` — replacing anything the client sent. One deliberate exception: a **`HEAD` on `github.com/<owner>/<repo>/releases/download/…`** is forwarded with the header _removed_. GitHub routes a release-asset `HEAD` carrying any `Authorization` to a legacy `objects.githubusercontent.com` pre-signed URL that answers `401` to every method, while an anonymous `HEAD` gets the working `release-assets.githubusercontent.com` CDN — so tools that probe with `HEAD` before `GET` (`uv`, `pip`) could not install from a release-asset URL at all. The credential buys nothing there: that endpoint doesn't accept token auth in the first place (see the limitation on private release assets below). `GET` on the same path keeps its credential, as does everything else. `/root/.config/gh` stays tmpfs-masked while the sidecar is active: the placeholder token already satisfies `gh`, so persisted in-container login state would just be a second, unneeded secret.

**Isolation and lifecycle.** Each invocation gets its own network (`claude-gh-<id>`) and sidecar (`claude-gh-proxy-<id>`), so concurrent sessions never share a token copy, a CA, or traffic. Teardown happens in `run.sh`'s existing `EXIT` trap, extended and installed _before_ any sidecar or network is created, so a failure mid-startup can't leak either resource. Startup is **fail-closed**: if the sidecar won't start or its CA can't be retrieved in time, `run.sh` tears everything down and exits with an error — it never falls back to forwarding the real token. `run.sh` prints the sidecar's container name at startup.

**Re-login and rotation are host-managed.** Under the proxy, GitHub auth is not something you manage from inside the container. `gh auth status` reports authentication via the `GH_TOKEN` env var (the placeholder), so `gh auth login` inside the container is a no-op: `gh` won't override an env-var token, `/root/.config/gh` is masked and ephemeral, and the sidecar rewrites the `Authorization` header on every request regardless of what's stored inside. To switch account or change scopes, do it **on the host** (`gh auth login` / `gh auth refresh`, or export a different `GH_TOKEN`) and relaunch — the sidecar reads the host token fresh at each container start, so a new session is how a changed credential flows in. A running container keeps working on the token it captured at launch until _that container_ exits; host-side changes never propagate into it live. (In-container `gh auth login` only works in the two no-sidecar modes: `--gh-direct`, and `--gh` when no host token was found.)

> **Revoking vs. re-login — they are not the same.** `gh auth logout` / `login` / `refresh` only change your host's _local_ credential store; none of them revokes a previously-issued token at GitHub. GitHub CLI's OAuth token is long-lived, so a token captured earlier (by a running sidecar, or exfiltrated) stays valid until you **explicitly revoke** it: for OAuth login, _GitHub → Settings → Applications → Authorized OAuth Apps → GitHub CLI → Revoke_; for a PAT, delete it under _Settings → Developer settings_. Relaunching only stops a _new_ container from using the old token — it does not invalidate the old one.

**Filtering and policy.** The generated Caddyfile blocks the one broadly destructive call by default: `DELETE` on `/repos/{owner}/{repo}` gets a `403` naming the claude-docker gh-proxy policy and never reaches GitHub. Extend it with `CLAUDE_DOCKER_GH_POLICY=<path>` pointing at a Caddyfile snippet — `run.sh` stages it and `import`s it into the **`api.github.com` site block only** (a snippet written for `github.com` or `uploads.github.com` traffic has no effect). Policy config lives solely in the sidecar; the agent container can neither read nor write it.

**Audit log.** Every proxied request (method, path, status — no headers, no token) is written as structured JSON to the sidecar's stdout. View it live with `docker logs <sidecar-name>` (the name `run.sh` prints at startup). The log is deliberately not persisted past the session — it's meant for live debugging, not a compliance trail. It's still a net improvement: host-side `gh` usage has no audit log at all today.

**`--gh-direct`** restores the pre-proxy behavior: the real token is forwarded straight into the agent container as `GH_TOKEN`, no sidecar involved. Use it for custom-hostname GitHub — Enterprise **Server** (`github.mycompany.com`) or GHEC data residency (`*.ghe.com`) — where the sidecar can't intercept the right hostnames, or on hosts that can't pull the Caddy image. github.com organizations under a GitHub Enterprise **Cloud** account use the standard `github.com` / `api.github.com` hostnames and _are_ fully covered by the proxy — `--gh-direct` is only needed for organizations on a genuinely custom hostname. Passing `--gh` and `--gh-direct` together is a startup error, and the statusline tags them distinctly (`gh` vs `gh-direct`) so a riskier direct-forwarding session is visible at a glance.

**Limitations:**

- TLS clients that don't read the OS trust store — notably Python's `certifi`-bundled CA set — get certificate errors against the three intercepted hostnames, since they never see the entrypoint-installed session CA. `uv` is handled for you (`UV_SYSTEM_CERTS=1`, above); for others, point the tool at the system store explicitly (`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`, or `REQUESTS_CA_BUNDLE` for `requests`/`certifi` consumers) or use `--gh-direct`.
- Release assets in **private** repos aren't reachable via their `https://github.com/<owner>/<repo>/releases/download/…` URL. That's GitHub's behavior, not the proxy's: the web download path accepts only browser-session auth, so a token-authenticated request 404s with or without the proxy. Use the API asset endpoint instead — `gh release download`, or `GET /repos/{owner}/{repo}/releases/assets/{id}` with `Accept: application/octet-stream` — both of which go through `api.github.com` and work normally. Public release assets work directly.
- SSH remotes (`git@github.com`) remain unsupported, as before — `--gh` never mounted a key or agent. The failure mode changes from an auth prompt to connection-refused, since `git@github.com` now resolves to the sidecar on a port it doesn't serve.
- git-LFS is expected to work unchanged: the batch endpoint on `github.com` gets the same `Authorization` injection as any other git smart-HTTP request, and the actual object transfer happens against pre-signed, non-intercepted hosts. It's covered by the [manual checklist](maintenance.md#manual-fallback-checklist-macos) rather than called out as a limitation.

## Terraform Cloud workflow

Standard usage targets `app.terraform.io` (HCP Terraform):

```bash
# One-time on the host: writes ~/.terraform.d/credentials.tfrc.json
terraform login app.terraform.io

# Per session
claude-docker --tfe ~/repo

# Inside the container, fetch the project-pinned terraform version
tfenv install            # reads .terraform-version, downloads from releases.hashicorp.com
terraform plan
```

The image ships `tfenv` (a pure-bash terraform version manager) and **does not** ship a pre-installed `terraform` binary version — versions are project-pinned (`required_version` / `.terraform-version`) and a single bundled version would drift against real workspaces. `tfenv install` writes terraform binaries under `/opt/tfenv/versions/`, which is **not** in the `claude-code-root` named volume; downloads do not persist across `docker run --rm` exits. Power users can build a child image (`FROM claude-code:local`) that runs `tfenv install <version>` at build time to bake a specific version into a derived image.

Token alternative: instead of (or in addition to) the credentials file, export `TF_TOKEN_app_terraform_io=<token>` on the host and `--tfe` will forward it. The terraform CLI honours both.

## Private package registries

> **⚠️ Use with care — the npmrc/pip.conf mounts are whole-file, not just the registry line.** Everything in a mounted file becomes readable inside the container, including credentials and settings unrelated to your package feed. Inspect these files before using:
>
> - **`~/.npmrc`** often carries tokens for _several_ registries (npmjs.org, GitHub Packages, other scoped feeds) plus unrelated npm settings — all of it spills over, not just your private feed's entry.
> - **`pip.conf`** likewise carries any global pip settings you've set, not only `index-url`.
> - **`~/.netrc` is deliberately NOT mounted** — as a machine-keyed store of logins for arbitrary unrelated hosts it's the broadest offender, so `--registry` never forwards it. Put registry auth in `~/.npmrc` / `pip.conf` / the index URL / `UV_INDEX_*_PASSWORD` instead.
>
> The forwarded _env vars_ are tightly scoped (named individually), so the over-share is specific to the npmrc/pip.conf file mounts. To minimise exposure, prefer the env-var channel or keep registry-only config files, and remember the container has full network egress (see [Threat model](security.md#threat-model)).

`--registry` makes the in-container package managers resolve against a private feed (AWS CodeArtifact, Artifactory, Nexus, GitLab/Azure, …) the same way your pipelines do — without inventing any claude-docker-specific config. It surfaces the package managers' **own native config** from the host, read-only:

| Channel                       | npm / pnpm                                                                   | uv                                                                                                                                            | pip / pipenv                                                                                               |
| ----------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| Config file (`:ro` mount)     | `~/.npmrc` (or `npm_config_userconfig`)                                      | `~/.config/uv/uv.toml`                                                                                                                        | platform `pip.conf` (macOS: `~/Library/Application Support/pip/pip.conf`, Linux: `~/.config/pip/pip.conf`) |
| Env vars (forwarded when set) | `npm_config_registry`, `NPM_CONFIG_REGISTRY`, `NODE_AUTH_TOKEN`, `NPM_TOKEN` | `UV_INDEX_URL`, `UV_DEFAULT_INDEX`, `UV_EXTRA_INDEX_URL`, `UV_INDEX`, `UV_KEYRING_PROVIDER`, and any `UV_INDEX_<NAME>_USERNAME` / `_PASSWORD` | `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`, `PIP_TRUSTED_HOST`, `PIPENV_PYPI_MIRROR`                           |

(`~/.netrc` is intentionally absent from this table — see the caution above.)

Mounts are read-only and composable with other flags; `--registry` does **not** require `--aws`. Resolution policy is whatever your host config already expresses: setting a default registry/index natively _replaces_ the public default (confining resolution to your feed), and re-adding public registries is done in your own native config — the wrapper imposes no policy of its own.

If you've relocated your npm config via `npm_config_userconfig` / `NPM_CONFIG_USERCONFIG`, that path is sourced instead of `~/.npmrc` (and still mounted at the container's default `/root/.npmrc`), so a relocated config doesn't silently fall through to public npm.

Standard AWS CodeArtifact flow (the per-tool `login` commands write the token into the native config files the flag then mounts):

```bash
# One-time on the host, per ecosystem you use:
aws codeartifact login --tool npm --domain D --domain-owner ACCT --repository R   # → ~/.npmrc
aws codeartifact login --tool pip --domain D --domain-owner ACCT --repository R   # → pip.conf
# uv: export the index + token (uv has no `codeartifact login`):
export UV_INDEX_URL="https://aws:$(aws codeartifact get-authorization-token --domain D --domain-owner ACCT --query authorizationToken --output text)@D-ACCT.d.codeartifact.REGION.amazonaws.com/pypi/R/simple/"

# Per session
claude-docker --registry ~/repo
```

The captured token freezes for the life of the container (a CodeArtifact token is ≤12h) — when it expires, re-run the host `login`/`export` and relaunch. Same posture as the `--aws` SSO credentials.

**No Python is bundled.** `pip`/`pipenv` themselves are not in the image (uv fetches its own Python; project runtimes live in child images). Run a pip-based tool via `uvx pipenv …` — pipenv shells out to pip, which reads the forwarded `pip.conf` / `PIP_*`. Caveat: if your feed is fully locked down with no public upstream, `pipenv` itself must be mirrored there for `uvx` to fetch it.

**Build vs. runtime.** `--registry` is **runtime-only**. The image _build_ always resolves its own tooling (claude-code, openspec, pnpm) against the public npm registry / PyPI regardless of any private registry configured on your host — your `~/.npmrc` and `npm_config_*` env are neither in the build context nor inherited by Dockerfile `RUN` steps. That isolation is what keeps the build reproducible from the committed pins. Routing the build itself through a private registry is intentionally out of scope.
