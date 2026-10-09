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

**Filtering and policy.** The generated Caddyfile blocks the one broadly destructive call by default: `DELETE` on `/repos/{owner}/{repo}` (or its numeric-id alias `/repositories/{id}`) gets a `403` naming the claude-docker gh-proxy policy and never reaches GitHub. Extend it with `CLAUDE_DOCKER_GH_POLICY=<path>` pointing at a Caddyfile snippet — `run.sh` stages it and `import`s it into the **`api.github.com` site block only** (a snippet written for `github.com` or `uploads.github.com` traffic has no effect). Policy config lives solely in the sidecar; the agent container can neither read nor write it.

**Audit log.** Every proxied request (method, path, status — no headers, no token) is written as structured JSON to the sidecar's stdout. View it live with `docker logs <sidecar-name>` (the name `run.sh` prints at startup). The log is deliberately not persisted past the session — it's meant for live debugging, not a compliance trail. It's still a net improvement: host-side `gh` usage has no audit log at all today.

**`--gh-direct`** restores the pre-proxy behavior: the real token is forwarded straight into the agent container as `GH_TOKEN`, no sidecar involved. Use it for custom-hostname GitHub — Enterprise **Server** (`github.mycompany.com`) or GHEC data residency (`*.ghe.com`) — where the sidecar can't intercept the right hostnames, or on hosts that can't pull the Caddy image. github.com organizations under a GitHub Enterprise **Cloud** account use the standard `github.com` / `api.github.com` hostnames and _are_ fully covered by the proxy — `--gh-direct` is only needed for organizations on a genuinely custom hostname. Passing `--gh` and `--gh-direct` together is a startup error, and the statusline tags them distinctly (`gh` vs `gh-direct`) so a riskier direct-forwarding session is visible at a glance.

**Limitations:**

- TLS clients that don't read the OS trust store — notably Python's `certifi`-bundled CA set — get certificate errors against the three intercepted hostnames, since they never see the entrypoint-installed session CA. `uv` is handled for you (`UV_SYSTEM_CERTS=1`, above); for others, point the tool at the system store explicitly (`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`, or `REQUESTS_CA_BUNDLE` for `requests`/`certifi` consumers) or use `--gh-direct`.
- Release assets in **private** repos aren't reachable via their `https://github.com/<owner>/<repo>/releases/download/…` URL. That's GitHub's behavior, not the proxy's: the web download path accepts only browser-session auth, so a token-authenticated request 404s with or without the proxy. Use the API asset endpoint instead — `gh release download`, or `GET /repos/{owner}/{repo}/releases/assets/{id}` with `Accept: application/octet-stream` — both of which go through `api.github.com` and work normally. Public release assets work directly.
- SSH remotes (`git@github.com`) remain unsupported, as before — `--gh` never mounted a key or agent. The failure mode changes from an auth prompt to connection-refused, since `git@github.com` now resolves to the sidecar on a port it doesn't serve.
- git-LFS is expected to work unchanged: the batch endpoint on `github.com` gets the same `Authorization` injection as any other git smart-HTTP request, and the actual object transfer happens against pre-signed, non-intercepted hosts. It's covered by the [manual checklist](maintenance.md#manual-fallback-checklist-macos) rather than called out as a limitation.

## GitLab token discovery (`--glab`)

`glab auth login` on the host is enough; you don't have to export anything:

```bash
glab auth login --hostname gitlab.example.com   # one-time, on the host
GITLAB_HOST=gitlab.example.com claude-docker --glab ~/repo
```

If `GITLAB_TOKEN` is unset, the wrapper runs `glab config get token --host <host>` on the host and stops at the first host that returns a token. With `GITLAB_HOST` set, that is the only host it tries. Otherwise it tries the host of the first workspace's `origin` remote (read from the repository's git config; a worktree or submodule workspace uses its main repository's or module's config), then glab's default host (the `host:` key in glab's `config.yml`, else `gitlab.com`), skipping a host it already tried. A host keeps its port (`GITLAB_HOST=gitlab.example.com:8443`), except for an `ssh://` or `git@host:path` remote, whose port is the SSH port. The token is forwarded as `GITLAB_TOKEN` by name, never on the `docker run` command line. `GITLAB_HOST` is forwarded too: as set, or, when unset, as the host the token was found for, so the in-container glab talks to that instance instead of `gitlab.com`.

This is what makes keyring logins work. When glab keeps the token in the OS keyring (`use_keyring: true` for the host, no `token:` in `config.yml`), the read-only `glab-cli` mount carries no token, but `glab config get token --host` reads it from the keyring (glab's `internal/config/config.go`, `GetWithSource`; checked against glab 1.118.0 and 1.119.0). Without `--host` glab never consults per-host tokens, so the wrapper always passes it. The container gets a copy of `config.yml` with `use_keyring: false`: otherwise the in-container glab still reads `job_token` from the keyring (no env var covers it) and fails without D-Bus, even with `GITLAB_TOKEN` set.

An exported `GITLAB_TOKEN` always wins. If `glab` isn't installed or has no token for any of those hosts, the container starts without one and the wrapper prints a warning naming the hosts it tried. That matters because without a token, the in-container glab calls the GitLab API unauthenticated. Public projects still work, which hides the cause ([#126](https://github.com/schubergphilis/claude-docker/issues/126)). For an instance that isn't the first workspace's remote, set `GITLAB_HOST` or export `GITLAB_TOKEN` yourself.

## Terraform Cloud workflow

Standard usage targets `app.terraform.io` (HCP Terraform):

```bash
# One-time on the host: writes ~/.terraform.d/credentials.tfrc.json
terraform login app.terraform.io

# Per session
claude-docker --tfe ~/repo
```

Inside the session Claude runs `terraform` itself, or you type `! terraform plan`. The first `terraform` call installs the version `.terraform-version` names from `releases.hashicorp.com`: tfenv defaults `TFENV_AUTO_INSTALL` to true, so no `tfenv install` step is needed.

The image ships `tfenv` (a pure-bash terraform version manager) and **does not** ship a pre-installed `terraform` binary version — versions are project-pinned in `.terraform-version` (tfenv reads `required_version` from `*.tf` only when that file says `min-required` or `latest-allowed`) and a single bundled version would drift against real workspaces. Installed versions land under `/opt/tfenv/versions/`, which is **not** in the `claude-code-root` named volume; downloads do not persist across `docker run --rm` exits. Power users can build a child image (`FROM claude-code:local`) that runs `tfenv install <version>` at build time to bake a specific version into a derived image.

Token alternative: instead of (or in addition to) the credentials file, export `TF_TOKEN_app_terraform_io=<token>` on the host and `--tfe` will forward it. The terraform CLI honours both.

## Private package registries

> **⚠️ Use with care — the npmrc/pip.conf mounts are whole-file, not just the registry line.** Everything in a mounted file becomes readable inside the container, including credentials and settings unrelated to your package feed. Inspect these files before using:
>
> - **`~/.npmrc`** often carries tokens for _several_ registries (npmjs.org, GitHub Packages, other scoped feeds) plus unrelated npm settings — all of it spills over, not just your private feed's entry.
> - **`pip.conf`** likewise carries any global pip settings you've set, not only `index-url`.
> - **`~/.netrc` is deliberately NOT mounted** — as a machine-keyed store of logins for arbitrary unrelated hosts it's the broadest offender, so `--registry` never forwards it. Put registry auth in `~/.npmrc` / `pip.conf` / the index URL / `UV_INDEX_*_PASSWORD` instead.
>
> The forwarded _env vars_ are tightly scoped (named individually), so the over-share is specific to the npmrc/pip.conf file mounts. To minimise exposure, prefer the env-var channel or keep registry-only config files, and remember the container has full network egress, even under `--egress-lock` (which restricts model traffic only and logs the rest; see [Threat model](security.md#threat-model)).

`--registry` makes the in-container package managers resolve against a private feed (AWS CodeArtifact, Artifactory, Nexus, GitLab/Azure, …) the same way your pipelines do — without inventing any claude-docker-specific config. It surfaces the package managers' **own native config** from the host, read-only:

| Channel                       | npm / pnpm                                                                   | uv                                                                                                                                            | pip / pipenv                                                                                                                                 |
| ----------------------------- | ---------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| Config file (`:ro` mount)     | `~/.npmrc` (or `npm_config_userconfig`)                                      | `~/.config/uv/uv.toml` (Windows: `%APPDATA%\uv\uv.toml`)                                                                                      | platform `pip.conf` (macOS: `~/Library/Application Support/pip/pip.conf`, Linux: `~/.config/pip/pip.conf`, Windows: `%APPDATA%\pip\pip.ini`) |
| Env vars (forwarded when set) | `npm_config_registry`, `NPM_CONFIG_REGISTRY`, `NODE_AUTH_TOKEN`, `NPM_TOKEN` | `UV_INDEX_URL`, `UV_DEFAULT_INDEX`, `UV_EXTRA_INDEX_URL`, `UV_INDEX`, `UV_KEYRING_PROVIDER`, and any `UV_INDEX_<NAME>_USERNAME` / `_PASSWORD` | `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`, `PIP_TRUSTED_HOST`, `PIPENV_PYPI_MIRROR`                                                             |

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

**No Python is bundled.** `pip`/`pipenv` themselves are not in the image (uv fetches its own Python; project runtimes live in child images). Claude runs a pip-based tool via `uvx pipenv …` — pipenv shells out to pip, which reads the forwarded `pip.conf` / `PIP_*`. Caveat: if your feed is fully locked down with no public upstream, `pipenv` itself must be mirrored there for `uvx` to fetch it.

**Build vs. runtime.** `--registry` is **runtime-only**. The image _build_ always resolves its own tooling (claude-code, openspec, pnpm) against the public npm registry / PyPI regardless of any private registry configured on your host — your `~/.npmrc` and `npm_config_*` env are neither in the build context nor inherited by Dockerfile `RUN` steps. That isolation is what keeps the build reproducible from the committed pins. Routing the build itself through a private registry is intentionally out of scope.

## Custom model endpoint

`--api` points Claude Code at your own model endpoint — a LiteLLM proxy, an enterprise gateway — using [Claude Code's own env vars](https://code.claude.com/docs/en/env-vars). Export them on the host; the wrapper forwards each one that is set by name only (`-e NAME`), so values never appear on the `docker run` command line:

```bash
export ANTHROPIC_BASE_URL=https://litellm.internal
export ANTHROPIC_AUTH_TOKEN=...                        # or ANTHROPIC_API_KEY
export CLAUDE_DOCKER_API_CA=~/certs/internal-ca.pem    # only if the gateway uses a private CA
claude-docker --api ~/repo
```

Forwarded: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, the deprecated `ANTHROPIC_SMALL_FAST_MODEL`, and two gateway knobs: `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` stops the experimental `anthropic-beta` headers that gateways routing to non-Anthropic models often reject, and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` tells Claude Code the real context window of a model name it doesn't recognise (e.g. `1000000`), so auto-compact doesn't hold the session to a conservative default.

`--egress-lock` sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` itself (see [API egress lock](#api-egress-lock)); plain `--api` doesn't. Other privacy switches such as `DISABLE_TELEMETRY` / `DISABLE_ERROR_REPORTING` are not gateway config and not secrets, so `--api` doesn't forward them: put them in the `env` block of `settings.docker.json` (see [Host config parity](usage.md#host-config-parity)) to apply them to every session.

**A gateway token is required.** `--api` refuses to start unless `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` is set and non-empty. Without one, Claude Code falls back to the claude.ai OAuth login in the volume and sends _that_ token to the gateway as its bearer.

**Private CA.** `CLAUDE_DOCKER_API_CA` (PEM) is mounted read-only and installed into the container's system trust store by the entrypoint, before privilege drop — the same step that installs the `--gh` sidecar CA. Claude Code trusts the OS store by default, so nothing else is needed. A set path that isn't a file is a startup error. Ignored without `--api`. The CA goes into the system trust store, so it is trusted for **every** TLS connection in the container (git, npm, uv, curl), not only the gateway. Fine for a corporate root CA; for a gateway-specific self-signed CA it widens trust beyond that host.

**Not covered yet:** Amazon Bedrock and Google Vertex (`CLAUDE_CODE_USE_BEDROCK` / `CLAUDE_CODE_USE_VERTEX`) need cloud credentials as well as endpoint config, and are deferred to a follow-up.

**File-based alternative.** Claude Code's settings accept an `env` block, so the same variables can live in `settings.docker.json` (see [Host config parity](usage.md#host-config-parity)) without `--api`:

```json
{ "env": { "ANTHROPIC_BASE_URL": "https://litellm.internal", "ANTHROPIC_AUTH_TOKEN": "..." } }
```

This puts the token **in plaintext in a host file**, copied into every session whether or not you want the gateway that run. Prefer `--api` with the token exported from your shell or a secret manager (see [`ANTHROPIC_AUTH_TOKEN` from 1Password](#anthropic_auth_token-from-1password)). Same trap as above: an `env` block with `ANTHROPIC_BASE_URL` but no token sends the OAuth token to the gateway, and `--api`'s check doesn't cover this route, so always set the token alongside it. This route also gets **no** [egress lock](#api-egress-lock): the session keeps full network egress.

### `ANTHROPIC_AUTH_TOKEN` from 1Password

Keep the gateway token in 1Password and let the 1Password CLI resolve it on the host at launch, so the plaintext token never sits in a file or your shell profile:

1. **One-time setup.** Install the CLI (`brew install 1password-cli`) and, in the 1Password app, turn on _Settings → Developer → Integrate with 1Password CLI_, so `op` unlocks with Touch ID instead of a separate sign-in. Check it with `op whoami`.
2. **Get the secret reference.** In the app, open the item and use the field's ▾ menu → _Copy Secret Reference_ (or `op item get "<item>" --vault <vault> --format json`). It looks like `op://<vault>/<item>/<field>`. Test it:

   ```bash
   op read "op://Employee/litellm/credential"
   ```

3. **Export the reference, not the secret**, e.g. in `~/.zshrc`. It is only a pointer, so it is safe in a file:

   ```bash
   export ANTHROPIC_BASE_URL=https://litellm.internal
   export ANTHROPIC_AUTH_TOKEN="op://Employee/litellm/credential"
   ```

4. **Launch through `op run`**, which swaps the reference for the real value before `claude-docker` starts. Touch ID prompts once, on the host:

   ```bash
   op run --no-masking -- claude-docker --api ~/repo
   # optional: alias claude-llm='op run --no-masking -- claude-docker --api'
   ```

Notes:

- `--no-masking` is required: with masking on, `op` pipes stdout/stderr and Claude's interactive screen breaks.
- Forget `op run` and the literal `op://…` string is forwarded as the token; the gateway answers 401.
- Use `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`: it is sent as `Authorization: Bearer` (what LiteLLM expects) and skips Claude's "use this API key?" prompt.
- A host `apiKeyHelper` in `~/.claude/settings.json` is not used in the container: that file isn't forwarded, and `op` isn't in the image. An existing helper script still works when run on the host: `ANTHROPIC_AUTH_TOKEN="$(~/.claude/litellm_key.sh)" claude-docker --api ~/repo`. If the script fails, the token is empty and `--api` refuses to start.
- The token is read once, when the container starts (it isn't refreshed like `apiKeyHelper`), so start a new session after rotating it.

## Azure DevOps Server with a private CA

An on-prem Azure DevOps Server usually serves TLS from an internal CA. Point `CLAUDE_DOCKER_AZ_CA` at it:

```bash
export CLAUDE_DOCKER_AZ_CA=~/.azure/tfs-ca.pem
claude-docker --az ~/repo
```

Under `--az`, `CLAUDE_DOCKER_AZ_CA` (PEM) is mounted read-only and installed into the container's system trust store by the entrypoint, before privilege drop, so `az` **and** `git` / `curl` to the server trust it. The host path itself is not forwarded; inside the container the `az` wrapper points `REQUESTS_CA_BUNDLE` at the system bundle (Mozilla roots plus your CA). A set path that isn't a file is a startup error. Ignored without `--az`. A host `REQUESTS_CA_BUNDLE` is deliberately not used: it is often set for other reasons, and this CA is trusted for **every** TLS connection in the container (git, npm, uv, curl), not only the server. Prefer a PEM with just the server's CA over a full bundle.

## API egress lock

`--egress-lock` (with `--api`) locks Claude Code's **model traffic** to your `ANTHROPIC_BASE_URL` gateway and logs every connection the session makes, so you can show a customer that prompts only went to, say, an EU-hosted gateway. Everything else (git, npm, PyPI, the web) stays reachable: only model traffic is restricted, and there is no allowlist to maintain. It is a separate opt-in because most gateway users don't need it: plain `--api` sessions, and sessions without `--api`, are unchanged. `--egress-lock` without `--api` refuses to start.

For a team, that is one env file and one command:

```bash
# team-eu.env (secrets as op:// references, see ANTHROPIC_AUTH_TOKEN from 1Password)
ANTHROPIC_BASE_URL=https://llm-gateway.example.eu
ANTHROPIC_AUTH_TOKEN=op://Team/llm-gateway/token
```

```bash
op run --env-file team-eu.env --no-masking -- claude-docker --api --egress-lock ~/repo
```

**What is enforced.** The proxy allows the `ANTHROPIC_BASE_URL` host, on its own port as well as 80/443 (so a gateway on `:8443` or LiteLLM's `:4000` works), and refuses the model providers' own hosts: `*.anthropic.com`, `*.claude.ai`, `*.claude.com`. Every other host on ports 80/443 is allowed. `run.sh` refuses to start when `ANTHROPIC_BASE_URL` is unset (Claude Code would call `api.anthropic.com`), points at one of those hosts, or has a port that isn't a number from 1 to 65535. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` is set in the container, so Claude Code's telemetry, error reporting and updater don't try the blocked hosts.

**The endpoint can't be moved by a project.** Claude Code would otherwise take `ANTHROPIC_BASE_URL` from a workspace's `.claude/settings.json` over the environment, and a project could switch on its Bedrock, Vertex or Foundry backend with a base URL of its own. Under the lock, `run.sh` mounts read-only Claude Code [managed settings](https://code.claude.com/docs/en/settings) at `/etc/claude-code/managed-settings.json`. They set `ANTHROPIC_BASE_URL` to your endpoint and switch those three backends off, and they take precedence over project settings, `settings.local.json` and `--settings`. CI checks that precedence against the image's Claude Code on every change (`tests/managed-settings-precedence.sh`).

**How it works.** The agent container is attached only to a per-session network created with `--internal` (`claude-egress-<id>`). That network has no gateway, so a raw socket, a direct IP, or a DNS lookup has nowhere to go. The only way out is a per-session squid forward proxy (`claude-egress-proxy-<id>`) that sits on that network and on a normal one. That is what makes its log complete. The agent gets `http_proxy` / `https_proxy` (both spellings) pointing at it. HTTPS goes through `CONNECT`, so TLS stays end-to-end: the proxy sees hostnames, never request contents or tokens, and `CLAUDE_DOCKER_API_CA` works unchanged. The proxy is squid from this same image (installed from the Ubuntu archive), so there is no extra image to pull or pin. It runs as an unprivileged user with no capabilities. The agent container's capability set is unchanged.

**Always denied:** cloud metadata and link-local addresses (`169.254.0.0/16`, `fe80::/10`, `metadata.google.internal`, `metadata.azure.internal`), loopback, any port other than 80 and 443 (except the endpoint's own port, for the endpoint), and `CONNECT` to anything but 443. Private ranges are reachable, as without `--api`, so an on-prem git server or registry works.

**Evidence.** When the session ends, `run.sh` saves the proxy's access log to `~/.local/state/claude-docker/egress/<start>-<id>.log` (`$XDG_STATE_HOME` if set), with a `.meta` file next to it: start and end time, user, host, workspaces, image and image ID, and the endpoint. The directory is never mounted into the container, and `run.sh` never rotates or deletes what is in it: the logs are the evidence, so pruning them is up to you. It prints what the proxy refused:

```text
claude-docker: egress proxy blocked: api.anthropic.com
claude-docker: egress log saved to ~/.local/state/claude-docker/egress/20260927T100000Z-a1B2c3.log
```

**Reporting** is not part of claude-docker. Build it from the saved `.log` (squid's default access-log format: field 4 is the result, field 7 the host) and `.meta` files. The log covers what left the container. That the gateway itself serves EU-hosted models has to be shown by the gateway (its config, or its provider's region).

**With `--gh`.** The auth-proxy sidecar joins the internal network too, and squid resolves `github.com` / `api.github.com` / `uploads.github.com` to it, so GitHub traffic goes agent → squid → auth proxy (token injected) → GitHub. Token handling is unchanged.

**Lifecycle.** Startup is fail-closed. If a network can't be created, or the proxy won't start or isn't accepting connections within 15s, `run.sh` aborts before the agent container starts; it never falls back to open egress. Teardown uses the same `EXIT` trap as the gh sidecar, and saves the log first.

**Limitations:**

- SSH remotes (port 22) and every other non-HTTP protocol are blocked. Use HTTPS remotes.
- Node's built-in `fetch` ignores proxy env vars, so scripts that use it fail closed. Claude Code, npm, pnpm, pip, uv, curl and Go honour them.
- An `ANTHROPIC_BASE_URL` set only in `settings.docker.json` isn't visible to `run.sh`, which then refuses to start. Export it on the host instead.
- A `CONNECT` to a provider's raw IP address isn't matched by the host deny. Claude Code never does that, and it would show up in the log.
- A `run.sh` killed with `SIGKILL` never runs its `EXIT` trap, so that session's log is lost.
- The endpoint pin is for Claude Code. Any other program in the session can reach every host that isn't a provider's, by design. Without TLS interception the log shows those connections, not what they carried.
- The pin covers the model backends Claude Code has today: the Anthropic API, Bedrock, Vertex and Foundry. A backend added in a later Claude Code would have to be switched off too. The CI precedence test is where that shows up when the `claude-code` pin moves.
- The log can be incomplete. squid comes from the Ubuntu archive, which can lag upstream security fixes: the packaged version is affected by CVE-2026-61642 (request smuggling via `Transfer-Encoding`), and a smuggled request doesn't appear in the access log. It doesn't get past the provider deny.
- DNS closure relies on Docker ≥ 26, which stopped forwarding external queries from internal networks. Older engines leave a DNS side channel.
- Podman isn't covered by CI. It was validated by hand on Windows 11 with rootless podman 6.0.2 (netavark), where the internal network, DNS closure and teardown behave as on Docker.
