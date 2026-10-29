# Auth model

[← Back to the README](../README.md)

Credentials are opt-in per run — the [Credential opt-in](#credential-opt-in) table below gives the per-flag effect, mounts, and env-var forwarding. The sections after it cover the workflows that need more than a one-line table cell.

## Credential opt-in

**Credentials are off by default.** No AWS / GitHub / GitLab / Terraform Cloud / Azure DevOps / package-registry / model-endpoint config, tokens, or env vars reach the container unless you explicitly opt in:

| Flag | Effect |
| --- | --- |
| `--aws` | Mount `~/.aws/config` and `~/.aws/sso/` read-only and forward `AWS_PROFILE` / `AWS_REGION` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`. `~/.aws/credentials` (long-lived keys) and `~/.aws/cli/cache/` are **not** mounted. Without the flag, `/root/.aws/` is hidden by a tmpfs overlay; with it, the overlay narrows to `/root/.aws/cli/cache/` so the STS credentials the CLI derives in-session don't persist on the shared volume. |
| `--gh` | Starts a per-session **auth proxy sidecar** that holds the GitHub token — the agent container never sees it. Token discovery is unchanged (`GH_TOKEN` / `GITHUB_TOKEN`, else host `gh auth token`, else a silent skip with no sidecar and legacy no-token behavior). When a token is found, the agent container gets a placeholder `GH_TOKEN=claude-docker-proxy`, GitHub traffic is redirected to the sidecar, and the real `Authorization` header is injected in transit. `/root/.config/gh` stays masked while the sidecar is active. See [GitHub auth proxy](#github-auth-proxy). |
| `--gh-direct` | Legacy escape hatch: same token discovery as `--gh`, but forwards the real token straight into the agent container as `GH_TOKEN` — no sidecar. For custom-hostname GitHub (Enterprise **Server**, `*.ghe.com`) and hosts that can't run the sidecar. Mutually exclusive with `--gh` (combining both is a startup error) and shown as its own `gh-direct` statusline tag. Unmasks in-container `gh auth login` state, same as pre-proxy `--gh`. |
| `--glab` | Puts the GitLab token in the per-session **auth proxy sidecar**, which injects it for the one GitLab host it belongs to; the agent container gets the placeholder `GITLAB_TOKEN=claude-docker-proxy`. Token discovery: `GITLAB_TOKEN`, else host glab's stored token (keyring included) for `GITLAB_HOST`, else the first workspace's `origin` host, then glab's default host. If none is found it prints a warning. Mounts the platform-appropriate `glab-cli` config dir read-only (macOS: `~/Library/Application Support/glab-cli`, Windows: `%APPDATA%\glab-cli`, Linux: `~/.config/glab-cli`) with token values blanked in the `config.yml` copy, forwards `GITLAB_HOST`, and unmasks in-container glab state — without the flag, `/root/.config/glab-cli/` is hidden by a tmpfs overlay. Blocks project/group deletion by default (`CLAUDE_DOCKER_GLAB_POLICY` extends). See [GitLab token discovery](#gitlab-token-discovery---glab) and [GitLab auth proxy](#gitlab-auth-proxy). |
| `--glab-direct` | Same as `--glab`, but forwards the real `GITLAB_TOKEN` into the agent container — no sidecar. For GitLab hosts the proxy can't serve (plain `http://`, an IP address, a private-CA certificate). Mutually exclusive with `--glab`. |
| `--tfe` | Mount `~/.terraform.d/credentials.tfrc.json` (Windows: `%APPDATA%\terraform.d\credentials.tfrc.json`) read-only when present and forward `TF_TOKEN_app_terraform_io`. Targets `app.terraform.io` (HCP Terraform) only — self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are not forwarded. Unmasks in-container `terraform login` state — without the flag, `/root/.terraform.d/` is hidden by a tmpfs overlay. See [Terraform Cloud workflow](#terraform-cloud-workflow). |
| `--az` | Azure DevOps (Services or on-prem Server): forward `AZURE_DEVOPS_EXT_PAT` (the PAT `az devops` / `repos` / `boards` / `pipelines` authenticate with) and `AZURE_DEVOPS_ORG_URL` (the default organization — the one place the hostname comes from, so a Server URL works as well as `dev.azure.com`). No host `~/.azure` file is mounted — not the profile (tenant/subscription IDs, account name), not the token caches (`msal_token_cache.json`, `accessTokens.json`) — and there is no `gh auth token`-style discovery: `az` has no command that prints a PAT, so it comes from your environment (keep it in 1Password and launch through `op run`, as in [`ANTHROPIC_AUTH_TOKEN` from 1Password](#anthropic_auth_token-from-1password)). Without the flag, `/root/.azure/` is hidden by a tmpfs overlay. General Azure resource management (`az vm`, service principals, `ARM_*`) is out of scope: the image ships `azure-cli-core` + the `azure-devops` extension, not the full `azure-cli`. Optional private CA via `CLAUDE_DOCKER_AZ_CA` — see [Azure DevOps Server with a private CA](#azure-devops-server-with-a-private-ca). |
| `--registry` | Surface host-native private package-registry config so in-container `uv` / `pnpm` / pip installs resolve against your private feed (CodeArtifact, Artifactory, Nexus, …) instead of public npm/PyPI. Read-only mounts of `~/.npmrc` / `uv.toml` / `pip.conf` plus `UV_INDEX_*` / `npm_config_registry` / `PIP_*` env when set. `~/.netrc` is intentionally **not** mounted (too broad). Runtime-only; the build is unaffected. **Whole-file mounts** — see [Private package registries](#private-package-registries) for the full channel list and the scoping caution. |
| `--api` | Claude Code talks to your LLM gateway (LiteLLM, enterprise proxy) instead of the in-container OAuth login. `ANTHROPIC_BASE_URL` and the `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` credential go to the per-session **auth proxy sidecar**; the agent container gets a sidecar base URL and placeholders. `ANTHROPIC_CUSTOM_HEADERS` / `ANTHROPIC_MODEL` / `ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU}_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL` / `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS` / `CLAUDE_CODE_MAX_CONTEXT_TOKENS` are forwarded by name when set. Optional private CA via `CLAUDE_DOCKER_API_CA`. Bedrock/Vertex are not covered yet. See [Custom model endpoint](#custom-model-endpoint). |
| `--api-direct` | Same as `--api`, but forwards the base URL and credential into the agent container too — no sidecar. Mutually exclusive with `--api`. |
| `--egress-lock` | With `--api` or `--api-direct`: **lock model traffic** to the `ANTHROPIC_BASE_URL` endpoint and log the connections that go through its proxy; see [API egress lock](#api-egress-lock). |

Combine as needed: `claude-docker --aws --gh ~/repo`. Each proxied flag and its `-direct` variant are mutually exclusive: pass `--gh` or `--gh-direct`, `--glab` or `--glab-direct`, `--api` or `--api-direct`, never both of a pair.

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

**Isolation and lifecycle.** Each invocation gets its own network (`claude-auth-<id>`) and sidecar (`claude-auth-proxy-<id>`), so concurrent sessions never share a token copy, a CA, or traffic. It is one sidecar per session, not per flag: [`--glab`](#gitlab-auth-proxy) and [`--api`](#custom-model-endpoint) add their own sites to the same sidecar, under the same CA and audit log. (Before `--glab` and `--api` used it, the names were `claude-gh-<id>` / `claude-gh-proxy-<id>`; stopped leftovers with those names are still swept at startup.) Teardown happens in `run.sh`'s existing `EXIT` trap, extended and installed _before_ any sidecar or network is created, so a failure mid-startup can't leak either resource. Startup is **fail-closed**: if the sidecar won't start or its CA can't be retrieved in time, `run.sh` tears everything down and exits with an error — it never falls back to forwarding the real token. `run.sh` prints the sidecar's container name at startup.

**Re-login and rotation are host-managed.** Under the proxy, GitHub auth is not something you manage from inside the container. `gh auth status` reports authentication via the `GH_TOKEN` env var (the placeholder), so `gh auth login` inside the container is a no-op: `gh` won't override an env-var token, `/root/.config/gh` is masked and ephemeral, and the sidecar rewrites the `Authorization` header on every request regardless of what's stored inside. To switch account or change scopes, do it **on the host** (`gh auth login` / `gh auth refresh`, or export a different `GH_TOKEN`) and relaunch — the sidecar reads the host token fresh at each container start, so a new session is how a changed credential flows in. A running container keeps working on the token it captured at launch until _that container_ exits; host-side changes never propagate into it live. (In-container `gh auth login` only works in the two no-sidecar modes: `--gh-direct`, and `--gh` when no host token was found.)

> **Revoking vs. re-login — they are not the same.** `gh auth logout` / `login` / `refresh` only change your host's _local_ credential store; none of them revokes a previously-issued token at GitHub. GitHub CLI's OAuth token is long-lived, so a token captured earlier (by a running sidecar, or exfiltrated) stays valid until you **explicitly revoke** it: for OAuth login, _GitHub → Settings → Applications → Authorized OAuth Apps → GitHub CLI → Revoke_; for a PAT, delete it under _Settings → Developer settings_. Relaunching only stops a _new_ container from using the old token — it does not invalidate the old one.

**Filtering and policy.** The generated Caddyfile blocks the one broadly destructive call by default: `DELETE` on `/repos/{owner}/{repo}` (or its numeric-id alias `/repositories/{id}`) gets a `403` naming the claude-docker gh-proxy policy and never reaches GitHub. Extend it with `CLAUDE_DOCKER_GH_POLICY=<path>` pointing at a Caddyfile snippet — `run.sh` stages it and `import`s it into the **`api.github.com` site block only** (a snippet written for `github.com` or `uploads.github.com` traffic has no effect). Policy config lives solely in the sidecar; the agent container can neither read nor write it.

**Audit log.** Every proxied request (method, host, path, status — no token) is written as structured JSON to the sidecar's stdout. View it live with `docker logs <sidecar-name>` (the name `run.sh` prints at startup). The log is deliberately not persisted past the session — it's meant for live debugging, not a compliance trail. It's still a net improvement: host-side `gh` usage has no audit log at all today.

**`--gh-direct`** restores the pre-proxy behavior: the real token is forwarded straight into the agent container as `GH_TOKEN`, no sidecar involved. Use it for custom-hostname GitHub — Enterprise **Server** (`github.mycompany.com`) or GHEC data residency (`*.ghe.com`) — where the sidecar can't intercept the right hostnames, or on hosts that can't pull the Caddy image. github.com organizations under a GitHub Enterprise **Cloud** account use the standard `github.com` / `api.github.com` hostnames and _are_ fully covered by the proxy — `--gh-direct` is only needed for organizations on a genuinely custom hostname. Passing `--gh` and `--gh-direct` together is a startup error, and the statusline tags them distinctly (`gh` vs `gh-direct`) so a riskier direct-forwarding session is visible at a glance.

**Limitations:**

- TLS clients that don't read the OS trust store — notably Python's `certifi`-bundled CA set — get certificate errors against the three intercepted hostnames, since they never see the entrypoint-installed session CA. `uv` is handled for you (`UV_SYSTEM_CERTS=1`, above); for others, point the tool at the system store explicitly (`SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt`, or `REQUESTS_CA_BUNDLE` for `requests`/`certifi` consumers) or use `--gh-direct`.
- Release assets in **private** repos aren't reachable via their `https://github.com/<owner>/<repo>/releases/download/…` URL. That's GitHub's behavior, not the proxy's: the web download path accepts only browser-session auth, so a token-authenticated request 404s with or without the proxy. Use the API asset endpoint instead — `gh release download`, or `GET /repos/{owner}/{repo}/releases/assets/{id}` with `Accept: application/octet-stream` — both of which go through `api.github.com` and work normally. Public release assets work directly.
- SSH remotes (`git@github.com`) remain unsupported, as before — `--gh` never mounted a key or agent. The failure mode changes from an auth prompt to connection-refused, since `git@github.com` now resolves to the sidecar on a port it doesn't serve. See [SSH remotes](#ssh-remotes).
- git-LFS is expected to work unchanged: the batch endpoint on `github.com` gets the same `Authorization` injection as any other git smart-HTTP request, and the actual object transfer happens against pre-signed, non-intercepted hosts. It's covered by the [manual checklist](maintenance.md#manual-fallback-checklist-macos) rather than called out as a limitation.

## GitLab token discovery (`--glab`)

`glab auth login` on the host is enough; you don't have to export anything:

```bash
glab auth login --hostname gitlab.example.com   # one-time, on the host
GITLAB_HOST=gitlab.example.com claude-docker --glab ~/repo
```

If `GITLAB_TOKEN` is unset, the wrapper runs `glab config get token --host <host>` on the host and stops at the first host that returns a token. With `GITLAB_HOST` set, that is the only host it tries. Otherwise it tries the host of the first workspace's `origin` remote (read from the repository's git config; a worktree or submodule workspace uses its main repository's or module's config), then glab's default host (the `host:` key in glab's `config.yml`, else `gitlab.com`), skipping a host it already tried. A host keeps its port (`GITLAB_HOST=gitlab.example.com:8443`), except for an `ssh://` or `git@host:path` remote, whose port is the SSH port. Under `--glab` the token goes only to the auth proxy sidecar (as an environment variable, never on the `docker run` command line) and the agent container gets the `GITLAB_TOKEN=claude-docker-proxy` placeholder; under `--glab-direct` it is forwarded into the agent container as `GITLAB_TOKEN` by name. `GITLAB_HOST` is forwarded too: as set, or, when unset, as the host the token was found for, so the in-container glab talks to that instance instead of `gitlab.com`.

This is what makes keyring logins work. When glab keeps the token in the OS keyring (`use_keyring: true` for the host, no `token:` in `config.yml`), the read-only `glab-cli` mount carries no token, but `glab config get token --host` reads it from the keyring (glab's `internal/config/config.go`, `GetWithSource`; checked against glab 1.118.0 and 1.119.0). Without `--host` glab never consults per-host tokens, so the wrapper always passes it. The container gets a copy of `config.yml` with `use_keyring: false`: otherwise the in-container glab still reads `job_token` from the keyring (no env var covers it) and fails without D-Bus, even with `GITLAB_TOKEN` set.

An exported `GITLAB_TOKEN` always wins. If `glab` isn't installed or has no token for any of those hosts, the container starts without one and the wrapper prints a warning naming the hosts it tried. That matters because without a token, the in-container glab calls the GitLab API unauthenticated. Public projects still work, which hides the cause ([#126](https://github.com/schubergphilis/claude-docker/issues/126)). For an instance that isn't the first workspace's remote, set `GITLAB_HOST` or export `GITLAB_TOKEN` yourself.

### GitLab auth proxy

Under `--glab` the token, exported or discovered, never enters the agent container. It goes to the session's [auth proxy sidecar](#github-auth-proxy), which adds it to requests in transit. The agent container gets the placeholder `GITLAB_TOKEN=claude-docker-proxy`, which is enough for `glab` to consider itself authenticated.

- **One host is proxied:** the host the token belongs to. That is `GITLAB_HOST` when set, else the host discovery found the token for, else, for an exported token, glab's default host (the `host:` key in glab's `config.yml`, else `gitlab.com`). An exported token is never tied to the `origin` host, which may not be GitLab at all. Neither is a token that host glab returns for any host (`GITLAB_ACCESS_TOKEN`, `OAUTH_TOKEN`, or a legacy top-level `token:` in `config.yml`): it goes to the default host, like an exported one. Its port is kept, so `gitlab.example.com:8443` works. That host resolves to the sidecar via `--add-host`, and the sidecar terminates TLS for it with the session CA. Other hostnames, such as a separate `registry.gitlab.example.com`, resolve normally and never see the token.
- **What gets the token:**
  - `/api/…` (REST and GraphQL) gets `Authorization: Bearer <token>`, which GitLab accepts for PATs and OAuth tokens alike.
  - Git smart-HTTP paths (`info/refs`, `git-upload-pack`, `git-receive-pack`) get `Basic oauth2:<token>`, so `git clone` / `push` over HTTPS work with no credential prompt.
  - Every other path is forwarded with no credential, Git LFS paths (`info/lfs/…`, `gitlab-lfs/…`) included. GitLab's LFS batch response hands a usable credential back to the client, so injecting the token there would let the container read one. Git LFS against a private project therefore needs `--glab-direct`.
  - Any `Authorization`, `PRIVATE-TOKEN` or `JOB-TOKEN` header the client sent is removed first.
- **The mounted `config.yml` copy** also has every token value blanked, even when no token was found (`token`, `job_token`, `oauth2_refresh_token`, for every host), so tokens for other GitLab instances stay out too.
- **Policy:** the sidecar answers these with `403`, and they never reach GitLab:
  - `DELETE` of a project or group (`/api/v4/projects/:id`, `/api/v4/groups/:id`, numeric id or URL-encoded path), and a `POST` to the same paths, which GitLab turns into a `DELETE` when it carries `_method=delete` or `X-HTTP-Method-Override: DELETE`.
    The project and group imports (`POST /api/v4/projects/import`, `/projects/remote-import`, `/projects/remote-import-s3`, `/groups/import`) are the only `POST`s on those paths and stay allowed.
  - REST calls that hand the container a credential that outlives the session: personal access tokens (`/personal_access_tokens/:id/rotate`, `self` included; `/user/personal_access_tokens`; `/users/:id/personal_access_tokens`), impersonation tokens, project and group access tokens and their rotation, deploy tokens, group service-account tokens, SSH and GPG keys (`/user/keys`, `/user/gpg_keys`, `/users/:id/keys`), login emails (`/user/emails`, `/users/:id/emails`, since GitLab sends a password reset to a verified secondary address), deploy keys (`/projects/:id/deploy_keys`, and enabling one), runner tokens (`/user/runners`, `/runners`, and the token resets), pipeline trigger tokens (`/projects/:id/triggers`), cluster-agent tokens, project and group members and invitations (adding, changing, importing or approving one), LDAP and SAML group links, shares with another group, transfers, webhooks, integrations such as emails-on-push or Slack (`/integrations/` and the legacy `/services/`), push mirrors and pull mirrors (`/projects/:id/mirror/pull`), pipeline schedules (creating, editing or taking one over), and access-request approvals.
  - Admin-only calls that create lasting access: creating or editing a user (`POST /api/v4/users`, `PUT /api/v4/users/:id`), creating an OAuth application (`POST /api/v4/applications`), and changing instance settings (`PUT /api/v4/application/settings`).
  - A `PUT` on a bare project or group path (`/api/v4/projects/:id`, `/api/v4/groups/:id`), which changes its settings: visibility and access settings can open lasting access, and Caddy can't read the body to tell those apart. Change settings with `--glab-direct`. GraphQL mutations that create tokens are not filtered.
  - A `DELETE`, `POST` or `PUT` whose path percent-encodes a letter, digit or `-._~` (such as `/api/v4/%70rojects/1`). GitLab decodes those, so they could hide one of the calls above. Reads are not checked, since GitLab's own docs encode dots in file paths (`key%2Erb`), and `%2F` and other reserved characters are unaffected.

  The match runs on the raw request URI (origin-form, so an absolute-form request line such as `DELETE https://<host>/api/v4/…` is matched the same way) and allows repeated slashes and a `.json` suffix, both of which GitLab accepts. It is a best-effort filter for the paths GitLab is known to route, not a guarantee: scope the token itself to what the session needs.

  Extend the policy with `CLAUDE_DOCKER_GLAB_POLICY=<path>`, a Caddyfile snippet imported into the GitLab site block. A set path that isn't a readable file is a startup error.
- **Audit log** entries carry the GitLab host, method, path and status. Request headers are left out entirely.

**`--glab-direct`** keeps the previous behaviour: the real token is forwarded into the agent container as `GITLAB_TOKEN` and no GitLab site is added to the sidecar. Use it for hosts the proxy can't serve: a plain `http://` `GITLAB_HOST` or an IP address, both of which `--glab` rejects at startup, or a GitLab whose certificate chains to a private CA. Use it too for Git LFS on private projects, which `--glab` doesn't authenticate (see above). Passing `--glab` and `--glab-direct` together is a startup error.

**Limitations:**

- If glab's `config.yml` sets an `api_host` for the proxied host that differs from the host itself, glab sends API calls there. Those calls aren't intercepted and fail with the placeholder; the wrapper warns at startup. Remove the `api_host` or use `--glab-direct`.
- A short-lived glab OAuth token (about 2h) is captured at launch and isn't refreshed mid-session, the same as before. Relaunch to pick up a fresh one.
- Only `token` values are blanked in the mounted `config.yml`. Values under a host's `custom_headers` (for example a Cloudflare Access client secret) stay readable in the container, and the sidecar forwards those headers as sent. Keep secrets out of `custom_headers`, or use `--glab-direct` knowingly.
- SSH remotes (`git@gitlab.example.com:…`) are unsupported, as before: no key or agent is mounted. See [SSH remotes](#ssh-remotes).

## Git over HTTPS

The forge flags also let git itself authenticate over HTTPS, so `git fetch` / `push` work without a prompt. Each flag adds a git credential helper scoped to its own host, so git never offers that token to any other host:

| Flag | Host | Credential helper |
| --- | --- | --- |
| `--gh` | `github.com` | none needed: the sidecar injects the token |
| `--gh-direct` | `github.com` | `gh auth git-credential` |
| `--glab` | the proxied GitLab host | none needed: the sidecar injects the token |
| `--glab-direct` | `GITLAB_HOST` (as set or discovered), else `gitlab.com` | `glab auth git-credential` |
| `--az` | host of `AZURE_DEVOPS_ORG_URL`, else `dev.azure.com` | answers with `AZURE_DEVOPS_EXT_PAT`, read from the container env when git calls it |

The helpers are passed as `GIT_CONFIG_*` env, so nothing is written to `~/.gitconfig`. `--gh-direct` covers `github.com` only; a GitHub Enterprise Server host gets no helper.

### SSH remotes

The container has no SSH key or agent, on purpose, so git can't use an SSH remote (`git@host:…`, `ssh://…`) from inside it. Switch the remote to HTTPS once, on the host:

```bash
git remote set-url origin https://github.com/org/repo.git                       # was git@github.com:org/repo.git
git remote set-url origin https://gitlab.example.com/grp/repo.git               # was git@gitlab.example.com:grp/repo.git
git remote set-url origin https://dev.azure.com/org/proj/_git/repo              # was git@ssh.dev.azure.com:v3/org/proj/repo
git remote set-url origin https://ado.example.com/tfs/Coll/Proj/_git/repo       # was ssh://ado.example.com:22/tfs/Coll/Proj/_git/repo
```

Or clone over HTTPS in the first place. Run `set-url` on the host: inside the container, `.git/config` is a single-file bind mount, and git's write to it fails with `Device or resource busy` ([#1](https://github.com/schubergphilis/claude-docker/issues/1)). For `glab repo clone` and friends, set `git_protocol` to `https` in the host's glab config (`glab config set git_protocol https --host gitlab.example.com`); the container gets a copy of that config.

If you'd rather not touch the remotes, add an `insteadOf` rule to the container's global git config, e.g. `git config --global url.https://github.com/.insteadOf git@github.com:`. It lives on the `claude-code-root` volume, so it lasts across sessions but not under `--ephemeral`. Azure DevOps can't be mapped this way: its SSH and HTTPS paths differ (`v3/org/proj/repo` vs `org/proj/_git/repo`). Don't set `GIT_CONFIG_*` in the `env` block of `settings.docker.json` for this: it would replace the wrapper's own `GIT_CONFIG_*` entries, credential helpers included.

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

**Build vs. runtime.** `--registry` is **runtime-only**. The image _build_ always resolves its own tooling (npm itself, claude-code, openspec, pnpm) against the public npm registry / PyPI regardless of any private registry configured on your host — your `~/.npmrc` and `npm_config_*` env are neither in the build context nor inherited by Dockerfile `RUN` steps. That isolation is what keeps the build reproducible from the committed pins. Routing the build itself through a private registry is intentionally out of scope.

## Custom model endpoint

`--api` points Claude Code at your own model endpoint — a LiteLLM proxy, an enterprise gateway — using [Claude Code's own env vars](https://code.claude.com/docs/en/env-vars). Export them on the host:

```bash
export ANTHROPIC_BASE_URL=https://litellm.internal
export ANTHROPIC_AUTH_TOKEN=...                        # or ANTHROPIC_API_KEY
export CLAUDE_DOCKER_API_CA=~/certs/internal-ca.pem    # only if the gateway uses a private CA
claude-docker --api ~/repo
```

**The credential stays in the sidecar.** `ANTHROPIC_BASE_URL` and whichever of `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY` you set go to the session's [auth proxy sidecar](#github-auth-proxy), not the agent container. Inside the container:

- `ANTHROPIC_BASE_URL` is `http://claude-docker-api-proxy:8080`, the sidecar on the session's private network.
- Each credential you set is the placeholder `claude-docker-proxy`.

The sidecar forwards to your `ANTHROPIC_BASE_URL` (default `https://api.anthropic.com`), keeping any path prefix such as `https://gw.internal/anthropic`. It replaces `x-api-key` / `Authorization` with the real values. A credential header you didn't provide is removed rather than passed on, so a claude.ai OAuth token from the volume can't leak to the gateway. Streaming responses pass straight through. The audit log (`docker logs <sidecar>`) records method, path and status, but no headers or bodies.

- The hop from Claude Code to the sidecar is plain HTTP. It runs on the session-private Docker network, which only the agent container and the sidecar are attached to, and the credential is never on it.
- With `ANTHROPIC_API_KEY`, Claude Code asks once whether to use the "custom API key", because the value it sees is now the placeholder. The placeholder never changes, so after one approval it is remembered in the volume.
- `ANTHROPIC_CUSTOM_HEADERS` is still forwarded into the agent container. If your gateway authenticates through a custom header, that header remains readable there; prefer `ANTHROPIC_AUTH_TOKEN` / `ANTHROPIC_API_KEY`.
- `ANTHROPIC_BASE_URL` must start with `http://` or `https://`.

**`--api-direct`** keeps the previous behaviour: every variable, the credential and base URL included, is forwarded into the agent container by name (`-e NAME`), with no sidecar involved. Passing `--api` and `--api-direct` together is a startup error.

Also forwarded by name, under either flag: `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, the deprecated `ANTHROPIC_SMALL_FAST_MODEL`, and two gateway knobs: `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` stops the experimental `anthropic-beta` headers that gateways routing to non-Anthropic models often reject, and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` tells Claude Code the real context window of a model name it doesn't recognise (e.g. `1000000`), so auto-compact doesn't hold the session to a conservative default.

`--egress-lock` sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` itself (see [API egress lock](#api-egress-lock)); plain `--api` doesn't. Other privacy switches such as `DISABLE_TELEMETRY` / `DISABLE_ERROR_REPORTING` are not gateway config and not secrets, so `--api` doesn't forward them: put them in the `env` block of `settings.docker.json` (see [Host config parity](usage.md#host-config-parity)) to apply them to every session.

**A gateway token is required.** `--api` and `--api-direct` refuse to start unless `ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` is set and non-empty. Without one, Claude Code falls back to the claude.ai OAuth login in the volume and sends _that_ token to the gateway as its bearer.

**Private CA.** `CLAUDE_DOCKER_API_CA` (PEM) is mounted read-only and installed into the container's system trust store by the entrypoint, before privilege drop — the same step that installs the auth-proxy sidecar CA. Under `--api` the sidecar also trusts it for its upstream connection, alongside the public roots, so a gateway with a public certificate keeps working when the variable names a corporate root. A set path that isn't a file is a startup error. Ignored without `--api` / `--api-direct`. The CA goes into the system trust store, so it is trusted for **every** TLS connection in the container (git, npm, uv, curl), not only the gateway. Fine for a corporate root CA; for a gateway-specific self-signed CA it widens trust beyond that host.

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
- Use `ANTHROPIC_AUTH_TOKEN`, not `ANTHROPIC_API_KEY`: it is sent to the gateway as `Authorization: Bearer` (what LiteLLM expects) and skips Claude's "use this API key?" prompt.
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

`--egress-lock` (with `--api` or `--api-direct`) locks Claude Code's **model traffic** to your `ANTHROPIC_BASE_URL` gateway and logs every connection that goes through its proxy, so you can show a customer that prompts only went to, say, an EU-hosted gateway. Everything else (git, npm, PyPI, the web) stays reachable: only model traffic is restricted, and there is no allowlist to maintain. It is a separate opt-in because most gateway users don't need it: plain `--api` / `--api-direct` sessions, and sessions without either, are unchanged. `--egress-lock` without one of them refuses to start.

For a team, that is one env file and one command:

```bash
# team-eu.env (secrets as op:// references, see ANTHROPIC_AUTH_TOKEN from 1Password)
ANTHROPIC_BASE_URL=https://llm-gateway.example.eu
ANTHROPIC_AUTH_TOKEN=op://Team/llm-gateway/token
```

```bash
op run --env-file team-eu.env --no-masking -- claude-docker --api --egress-lock ~/repo
```

**What is enforced.** Under `--api`, Claude Code talks to the [auth proxy sidecar](#custom-model-endpoint) at `http://claude-docker-api-proxy:8080`, through squid, and the sidecar forwards to `ANTHROPIC_BASE_URL`, the only upstream it has. Under `--api-direct`, Claude Code connects to `ANTHROPIC_BASE_URL` itself, through squid. Either way the proxy allows the `ANTHROPIC_BASE_URL` host, on its own port as well as 80/443 (so a gateway on `:8443` or LiteLLM's `:4000` works), and refuses the model providers' own hosts: `*.anthropic.com`, `*.claude.ai`, `*.claude.com`. Every other host on ports 80/443 is allowed. `run.sh` refuses to start when `ANTHROPIC_BASE_URL` is unset (Claude Code would call `api.anthropic.com`), points at one of those hosts, or has a port that isn't a number from 1 to 65535. `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1` are set in the container, so Claude Code's telemetry, error reporting, updater and official plugin marketplace install (`downloads.claude.ai`) don't try the blocked hosts. A claude.ai login stored on the `claude-code-root` volume is not used: the gateway token (or the approved `ANTHROPIC_API_KEY`, see _First run_) takes precedence, so Claude Code makes no account calls with it. Plugins or marketplaces you added yourself that live on a provider host are still refused.

**First run.** On a fresh `~/.claude.json` (a new `claude-code-root` volume, or every `--ephemeral` session), Claude Code's onboarding checks that it can reach `api.anthropic.com` and `platform.claude.com` unless it can tell that claude.ai login is off. The lock refuses both hosts, so the session would end with _Unable to connect to Anthropic services … ERR_PROXY_TUNNEL_. `ANTHROPIC_AUTH_TOKEN` turns login off by itself. `ANTHROPIC_API_KEY` only does once you've approved the key at Claude Code's "use this API key?" prompt, which comes after the check. Under `--egress-lock`, the entrypoint therefore records that approval in `~/.claude.json` for the forwarded `ANTHROPIC_API_KEY` (its last 20 characters, as the prompt would store them), before Claude Code starts. Under `--api` the key Claude Code sees is the sidecar's placeholder, so that is what gets approved. Without `--egress-lock`, the prompt is left to you.

**The endpoint can't be moved by a project.** Claude Code would otherwise take `ANTHROPIC_BASE_URL` from a workspace's `.claude/settings.json` over the environment, and a project could switch on another backend (Bedrock, Vertex, Foundry, Anthropic on AWS or Google Cloud, Mantle, a gateway) with a base URL of its own. Under the lock, `run.sh` mounts read-only Claude Code [managed settings](https://code.claude.com/docs/en/settings) at `/etc/claude-code/managed-settings.json`. They set `ANTHROPIC_BASE_URL` to your endpoint (under `--api`, to the sidecar's `http://claude-docker-api-proxy:8080`, which only forwards to your endpoint) and switch every other backend off. They also pin the proxy env (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` and their lowercase forms) to squid, so a project can't send Claude Code's model requests past the log, for example with `NO_PROXY=claude-docker-api-proxy`. They take precedence over project settings, `settings.local.json` and `--settings`. CI checks that precedence against the image's Claude Code on every change (`tests/integration/managed-settings-precedence.sh`), and fails when a Claude Code update adds a backend switch the managed settings don't cover.

**How it works.** The agent container is attached only to a per-session network created with `--internal` (`claude-egress-<id>`). That network has no gateway, so a raw socket, a direct IP, or a DNS lookup has nowhere to go. The ways out are a per-session squid forward proxy (`claude-egress-proxy-<id>`) that sits on that network and on a normal one, and, under `--api`, `--gh` or `--glab`, the auth-proxy sidecar, which only forwards to its fixed upstreams (see _With the auth-proxy sidecar_ below). The agent gets `http_proxy` / `https_proxy` (both spellings) pointing at it. HTTPS goes through `CONNECT`, so TLS stays end-to-end: the proxy sees hostnames, never request contents or tokens, and `CLAUDE_DOCKER_API_CA` works unchanged. The proxy is squid in its own small image: Alpine (digest-pinned) with its squid package, at least 7.6. `run.sh` builds it the first time you use `--egress-lock`, which needs access to Docker Hub and Alpine's package mirrors, and reuses it after that. The agent image doesn't contain squid. Set `CLAUDE_DOCKER_EGRESS_PROXY_IMAGE` to use an image you built or mirrored yourself. The proxy runs as the unprivileged `squid` user with no capabilities, and squid's cache manager is refused. The agent container's capability set is unchanged.

**Always denied:** cloud metadata and link-local addresses (`169.254.0.0/16`, `fe80::/10`, `100.100.100.200`, `fd00:ec2::254`, `metadata.google.internal`, `metadata.azure.internal`), loopback, any port other than 80 and 443 (except the endpoint's own port, for the endpoint, and the auth-proxy sidecar's own ports for its names: 8080 for `claude-docker-api-proxy`, and a `--glab` host's port), and `CONNECT` to anything but 443. Private ranges are reachable, as without `--api`, so an on-prem git server or registry works.

**Evidence.** When the session ends, `run.sh` saves the proxy's access log to `~/.local/state/claude-docker/egress/<start>-<id>.log` (`$XDG_STATE_HOME` if set), with a `.meta` file next to it: start and end time, user, host, workspaces, the agent image and the proxy image with their IDs, and the endpoint. The directory is never mounted into the container, and `run.sh` never rotates or deletes what is in it: the logs are the evidence, so pruning them is up to you. It prints what the proxy refused:

```text
claude-docker: egress proxy blocked: api.anthropic.com
claude-docker: egress log saved to ~/.local/state/claude-docker/egress/20260927T100000Z-a1B2c3.log
```

`run.sh` checks the copy. If the engine can't return the proxy's log, or returns it without squid's startup line because its log driver rotated or dropped the start (`max-size` in `daemon.json`, for example), it says so instead, and the file holds only what it got:

```text
claude-docker: the egress log in ~/.local/state/claude-docker/egress/20260927T100000Z-a1B2c3.log is incomplete: squid's startup line is gone, so the engine's log driver rotated or dropped the start of the session (check its max-size)
```

**Reporting** is not part of claude-docker. Build it from the saved `.log` (squid's default access-log format: field 4 is the result, field 7 the host) and `.meta` files. The log covers what left the agent container. Under `--api` that means the model requests appear as plain-HTTP requests to `http://claude-docker-api-proxy:8080/…`, not as a `CONNECT` to the gateway: the auth-proxy sidecar's own connection to `ANTHROPIC_BASE_URL` doesn't pass through squid. Its upstream is fixed to the host's `ANTHROPIC_BASE_URL` (the `.meta` file names it), and its audit log (`docker logs` on the sidecar, while the session runs) records each request's method, path and status. Under `--api-direct` the log has the `CONNECT` to the gateway itself. That the gateway itself serves EU-hosted models has to be shown by the gateway (its config, or its provider's region).

**With the auth-proxy sidecar** (`--api`, `--gh`, `--glab`). The sidecar joins the internal network too, and squid resolves the names it serves to it: `claude-docker-api-proxy`, `github.com` / `api.github.com` / `uploads.github.com`, and the `--glab` host. So GitHub traffic goes agent → squid → auth proxy (token injected) → GitHub, and likewise for GitLab and the model endpoint. Credential handling is unchanged. The sidecar reaches its upstreams over its own network, not through squid, so the squid log shows the agent's requests to the sidecar, not the sidecar's onward connections. The agent can also reach the sidecar directly: its names resolve to the sidecar's address on the internal network, so a client that ignores the proxy env, or a project that sets `NO_PROXY`, skips squid. Such a request still goes only to the sidecar's fixed upstream, so the lock holds, but it is in the sidecar's audit log, not in squid's.

**Lifecycle.** Startup is fail-closed. If a network can't be created, or the proxy won't start or isn't accepting connections within 15s, `run.sh` aborts before the agent container starts; it never falls back to open egress. Teardown uses the same `EXIT` trap as the auth-proxy sidecar, and saves the log first.

**Limitations:**

- SSH remotes (port 22) and every other non-HTTP protocol are blocked. Use HTTPS remotes.
- Node's built-in `fetch` ignores proxy env vars, so scripts that use it fail closed. Claude Code, npm, pnpm, pip, uv, curl and Go honour them.
- An `ANTHROPIC_BASE_URL` set only in `settings.docker.json` isn't visible to `run.sh`, which then refuses to start. Export it on the host instead.
- A `CONNECT` to a provider's raw IP address isn't matched by the host deny. Claude Code never does that, and it would show up in the log.
- A `run.sh` killed with `SIGKILL` never runs its `EXIT` trap, so that session's log is lost.
- The endpoint pin is for Claude Code. Any other program in the session can reach every host that isn't a provider's, by design. Without TLS interception the log shows those connections, not what they carried.
- The pin covers the model backends Claude Code has today: the Anthropic API, a gateway, Bedrock, Foundry, Anthropic on AWS or Google Cloud, Mantle and Vertex. A backend added in a later Claude Code would have to be switched off too. The CI precedence test is where that shows up when the `claude-code` pin moves.
- The squid log doesn't list requests another program sends straight to the auth-proxy sidecar, ignoring the proxy env. Claude Code's own can't skip it, because the managed settings pin its proxy env. Those requests can only reach the sidecar's fixed upstreams, and its audit log records them while the session runs.
- The log is only as complete as squid makes it. A request-smuggling bug, such as CVE-2026-61642 (fixed in squid 7.6, which the proxy image requires), can hide a request from the access log, though not get it past the provider deny. CI scans the proxy image for HIGH/CRITICAL CVEs like the agent image.
- The proxy image is built once and then reused. To take up a newer Alpine squid after a security fix, remove it (`docker image rm` the `claude-docker-egress-proxy:*` tag) and the next `--egress-lock` session rebuilds it.
- DNS closure relies on Docker ≥ 26, which stopped forwarding external queries from internal networks. Older engines leave a DNS side channel.
- Podman isn't covered by CI. It was validated by hand on Windows 11 with rootless podman 6.0.2 (netavark), where the internal network, DNS closure and teardown behave as on Docker.
