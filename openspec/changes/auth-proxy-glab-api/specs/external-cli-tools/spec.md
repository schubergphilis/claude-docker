# Spec Delta

## MODIFIED Requirements

### Requirement: Credentials opt-in

Host credentials (files or env vars) SHALL NOT reach the container unless the user explicitly opts in per-run. `run.sh` defaults to no credential mounts and no token env forwarding. Opt-ins are granted via dedicated flags:

- `--aws`: mount `~/.aws/config` at `/root/.aws/config:ro` and, when present, `~/.aws/sso/` at `/root/.aws/sso:ro`; forward `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` when set on the host.
- `--gh`: discover the host token from `GH_TOKEN` or `GITHUB_TOKEN`; if neither
  is set, `run.sh` SHALL attempt to retrieve the active token by running
  `gh auth token` on the host. A discovered token SHALL be provided only to the
  per-session auth proxy sidecar (see capability `gh-auth-proxy`) — it SHALL
  NOT be forwarded into the agent container, which instead receives the
  placeholder `GH_TOKEN=claude-docker-proxy` and reaches GitHub through the
  sidecar. If `gh` is not on the host PATH or the command fails, `run.sh`
  SHALL continue silently without a token and without a sidecar.
- `--gh-direct`: legacy escape hatch. Same token discovery as `--gh`, but the
  token is forwarded directly into the agent container as `GH_TOKEN` and no
  sidecar is started. Intended for custom-hostname GitHub (Enterprise Server /
  `*.ghe.com`) and hosts that cannot run the sidecar. Passing `--gh` and
  `--gh-direct` together SHALL exit with an error. The mode SHALL surface as
  a distinct `gh-direct` entry in `CLAUDE_DOCKER_FLAGS` so the statusline tag
  distinguishes it from proxied `gh`.
- `--glab`: mount the platform-appropriate glab config dir — `~/Library/Application Support/glab-cli` on macOS, `%APPDATA%\glab-cli` on Windows (Git Bash), `~/.config/glab-cli` on Linux and as the fallback everywhere — at `/root/.config/glab-cli:ro`; forward `GITLAB_HOST` when set on the host. The token is the host's `GITLAB_TOKEN` when set. If `GITLAB_TOKEN` is not set, `run.sh` SHALL attempt to retrieve the host glab token by running `glab config get token --host <host>` for each candidate host in turn, stopping at the first that returns a token. When `GITLAB_HOST` is set, its host (with any port) is the only candidate. Otherwise the candidates are, in order, the host of the first workspace's `remote.origin.url` (read as a file from the `config` in the repository's common git dir, `git rev-parse --git-common-dir`, so a worktree or submodule workspace resolves to its main repository's or module's config; skipped when `.git` or that `config` is a symlink or absent, or when the common git dir can't be resolved) and the host of glab's default host (`glab config get host`; `gitlab.com` if empty). A host keeps its port, except for an `ssh://` or scp-style (`user@host:path`) remote, where the port is the SSH port and SHALL be dropped. A host already tried SHALL NOT be tried or named again. That command also reads tokens glab stored in the OS keyring. The token's host is `GITLAB_HOST` when set, else the host discovery found the token for, else (an explicit `GITLAB_TOKEN` without `GITLAB_HOST`) the first candidate host. The token, set or discovered, SHALL be provided only to the per-session auth proxy sidecar (see capability `glab-auth-proxy`). It SHALL NOT be forwarded into the agent container, which instead receives the placeholder `GITLAB_TOKEN=claude-docker-proxy` and reaches the token's host through the sidecar. When `GITLAB_HOST` is not set on the host, `run.sh` SHALL also forward the token's host as `GITLAB_HOST`, by bare name, so the in-container glab targets the instance the token belongs to. If `glab` is not on the host PATH or returns no token for any candidate, `run.sh` SHALL continue without one and print a one-line warning to stderr naming the hosts tried and the `GITLAB_TOKEN` / `GITLAB_HOST` remedies; the warning SHALL NOT contain any token value. When the host glab config dir holds a `config.yml`, `run.sh` SHALL mount a copy of it with every `use_keyring:` value set to `false` (and, while the GitLab proxy is active, every token-valued key blanked, see `glab-auth-proxy`) read-only over `/root/.config/glab-cli/config.yml`, so the in-container glab never reads the OS keyring, which needs D-Bus that the container lacks; the host file SHALL NOT be modified, and the copy SHALL be removed when the session ends.
- `--glab-direct`: escape hatch. Same config mount, keyring rewrite and token discovery as `--glab`, but the token is forwarded directly into the agent container as `GITLAB_TOKEN`, by bare name, and the token's host is not proxied. The config copy keeps its tokens. Intended for GitLab hosts the proxy does not serve (plain `http://`, IP literal, private-CA upstream) and hosts that cannot run the sidecar. Passing `--glab` and `--glab-direct` together SHALL exit with an error. The mode SHALL surface as a distinct `glab-direct` entry in `CLAUDE_DOCKER_FLAGS`.
- `--tfe`: when present on the host, mount the `terraform login` credentials file — `%APPDATA%\terraform.d\credentials.tfrc.json` on Windows (Git Bash), `~/.terraform.d/credentials.tfrc.json` on Linux/macOS and as the fallback everywhere — at `/root/.terraform.d/credentials.tfrc.json:ro`; forward `TF_TOKEN_app_terraform_io` when set on the host. Targets `app.terraform.io` (HCP Terraform); self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are out of scope for this opt-in.
- `--az`: forward `AZURE_DEVOPS_EXT_PAT` and `AZURE_DEVOPS_ORG_URL` when set on the host, and SHALL NOT mount any host `~/.azure` file: the PAT is the whole credential, and the profile would only carry tenant / subscription IDs and the account name into the container. `AZURE_DEVOPS_ORG_URL` SHALL be the only source of the Azure DevOps hostname — nothing SHALL assume `dev.azure.com`, so Azure DevOps Server (on-prem, custom hostname) works the same as Services. `run.sh` SHALL NOT attempt host-side PAT discovery (`az` has no command that prints a usable PAT). When `CLAUDE_DOCKER_AZ_CA` is set on the host, `run.sh` SHALL mount the file it names read-only at `/usr/local/share/ca-certificates/claude-docker-az.crt`, the entrypoint SHALL install it into the system trust store before the privilege drop, and `az` SHALL use the system bundle; the host value itself SHALL NOT be forwarded. When it is set but does not name a file, `run.sh` SHALL exit 1 before starting any container. The host's `REQUESTS_CA_BUNDLE` SHALL NOT be read, since it is often set for unrelated reasons. The certificate is trusted for every TLS connection in the container, not only the Azure DevOps Server; the documentation SHALL say so. Targets the `azure-devops` extension only; general Azure resource management and its credentials (`ARM_*`, `AZURE_CLIENT_SECRET`, service principals) are out of scope for this opt-in.

All credential bind-mounts SHALL be read-only so a compromised container cannot rewrite host config or tokens. `~/.aws/credentials` and `~/.aws/cli/cache/` SHALL NEVER be mounted, even under `--aws`. Likewise nothing under `~/.azure/` SHALL be mounted under `--az` — in particular never the Azure token caches `msal_token_cache.json` or `accessTokens.json`.

The container's own `/root/.aws/cli/cache/` SHALL NOT survive the session that
wrote it. The AWS CLI caches assume-role and SSO-derived STS credentials there,
and `/root` is a persistent volume shared by every session, so without a mask
that cache outlives the run whose opt-in produced it. This mirrors the reason
the host path is never mounted: the same material is at stake whether it was
copied in from the host or derived inside the container.

#### Scenario: No flags means no credentials

- **GIVEN** host has `~/.aws/config`, `~/.config/glab-cli/config.yml`, `~/.terraform.d/credentials.tfrc.json`, and `GH_TOKEN=ghp_x` and `TF_TOKEN_app_terraform_io=tfc_x` exported
- **AND** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `/root/.aws/` is empty inside the container
- **AND** `/root/.config/glab-cli/` is empty inside the container
- **AND** `/root/.terraform.d/` is empty inside the container
- **AND** `echo $GH_TOKEN` inside the container is empty
- **AND** `echo $TF_TOKEN_app_terraform_io` inside the container is empty
- **AND** `/root/.azure/` is empty inside the container and `echo $AZURE_DEVOPS_EXT_PAT` is empty
- **AND** `gh auth status` inside the container reports "not logged in"

#### Scenario: --aws grants scoped AWS access

- **GIVEN** the host has completed `aws sso login --profile X` and exports `AWS_PROFILE=X`
- **WHEN** user runs `claude-docker --aws ~/repo`
- **THEN** `aws sts get-caller-identity` inside the container returns the host's identity
- **AND** `~/.aws/credentials` is not present inside the container
- **AND** writes to `/root/.aws/config` from inside the container fail with EROFS
- **AND** writes to `/root/.aws/sso/` from inside the container fail with EROFS
- **AND** `/root/.aws/cli/cache/` is empty at session start and its contents do not persist to a later session

#### Scenario: --glab grants read-only token access

- **GIVEN** the host has a valid `~/.config/glab-cli/config.yml`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `glab auth status` reports "logged in" without prompting
- **AND** writes to `/root/.config/glab-cli/` from inside the container fail with EROFS

#### Scenario: --glab turns the keyring off in the container

- **GIVEN** host glab's `config.yml` has `use_keyring: true` for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `/root/.config/glab-cli/config.yml` inside the container has `use_keyring: false`, its token values blanked, and otherwise matches the host file
- **AND** glab inside the container does not access the OS keyring or D-Bus
- **AND** the host `config.yml` is unchanged

#### Scenario: --glab falls back to the host glab token

- **GIVEN** `GITLAB_TOKEN` is not set on the host and `GITLAB_HOST=https://gitlab.example.com` is
- **AND** host `glab auth login` stored a token for `gitlab.example.com`, in `config.yml` or the OS keyring
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the sidecar holds that token for `gitlab.example.com` and the agent container receives `GITLAB_TOKEN=claude-docker-proxy` and `GITLAB_HOST`
- **AND** neither token nor host value appears in the `docker run` argv

#### Scenario: --glab discovers a keyring-held token

- **GIVEN** `GITLAB_TOKEN` is not set on the host
- **AND** host glab's `config.yml` has `use_keyring: true` and no `token` for the default host, the token living only in the OS keyring
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the token returned by host `glab config get token --host <host>` is the one the sidecar injects

#### Scenario: --glab keeps an explicit GITLAB_TOKEN

- **GIVEN** `GITLAB_TOKEN` is set on the host
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** host `glab` is not asked for a token and the sidecar injects the host's `GITLAB_TOKEN`
- **AND** the agent container's `GITLAB_TOKEN` is `claude-docker-proxy`

#### Scenario: --glab discovers the token for the workspace remote's host

- **GIVEN** neither `GITLAB_TOKEN` nor `GITLAB_HOST` is set on the host
- **AND** glab's default host is `gitlab.com`, but `~/repo`'s `origin` is `git@gitlab.example.com:group/project.git`
- **AND** host glab holds a token only for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the sidecar holds that token for `gitlab.example.com`
- **AND** the container receives `GITLAB_HOST=gitlab.example.com`, so the in-container glab does not target `gitlab.com`

#### Scenario: --glab discovers the origin host from a worktree workspace

- **GIVEN** neither `GITLAB_TOKEN` nor `GITLAB_HOST` is set on the host
- **AND** `~/wt` is a git worktree (its `.git` is a pointer file) of a repository whose `origin` is `git@gitlab.example.com:group/project.git`
- **AND** host glab holds a token only for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/wt`
- **THEN** the sidecar holds that token for `gitlab.example.com`

#### Scenario: --glab is silent when glab is unavailable

- **GIVEN** `GITLAB_TOKEN` is not set on the host
- **AND** `glab` is not on the host PATH, or has no token for any candidate host
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the container starts without `GITLAB_TOKEN`
- **AND** stderr carries one warning naming the hosts tried and suggesting `GITLAB_TOKEN` or `GITLAB_HOST`

#### Scenario: --glab keeps the GITLAB_HOST port

- **GIVEN** `GITLAB_TOKEN` is not set on the host and `GITLAB_HOST=gitlab.example.com:8443`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** host glab is asked for the token of `gitlab.example.com:8443`

#### Scenario: --glab finds the Windows config dir under %APPDATA%

- **GIVEN** `run.sh` runs under Git Bash on Windows
- **AND** the host glab config lives at `%APPDATA%\glab-cli`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** that directory is mounted read-only at `/root/.config/glab-cli`

#### Scenario: --gh keeps the host token out of the agent container

- **GIVEN** `GH_TOKEN=ghp_x` is exported in the host shell
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `echo $GH_TOKEN` inside the agent container prints `claude-docker-proxy`
- **AND** `gh api /user` inside the agent container succeeds via the sidecar

#### Scenario: --gh falls back to gh auth token for the sidecar

- **GIVEN** neither `GH_TOKEN` nor `GITHUB_TOKEN` is set in the host shell
- **AND** the host has `gh` on PATH and the user is authenticated (`gh auth status` succeeds)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** authenticated GitHub access works inside the agent container
- **AND** the token returned by host `gh auth token` is not present in the agent container's environment

#### Scenario: --gh is silent when gh is unavailable

- **GIVEN** neither `GH_TOKEN` nor `GITHUB_TOKEN` is set in the host shell
- **AND** `gh` is not on the host PATH (or `gh auth token` exits non-zero)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** the container starts without a sidecar, without a `GH_TOKEN` env var, and no error is printed

#### Scenario: --gh-direct restores legacy forwarding

- **GIVEN** `GH_TOKEN=ghp_x` is exported in the host shell
- **WHEN** user runs `claude-docker --gh-direct ~/repo`
- **THEN** `echo $GH_TOKEN` inside the agent container prints `ghp_x`
- **AND** no sidecar container is started

#### Scenario: --gh and --gh-direct together are rejected

- **WHEN** user runs `claude-docker --gh --gh-direct ~/repo`
- **THEN** `run.sh` exits non-zero with an error naming the conflicting flags
- **AND** no container or sidecar is started

#### Scenario: --glab-direct restores legacy forwarding

- **GIVEN** `GITLAB_TOKEN=glpat_x` is exported in the host shell
- **WHEN** user runs `claude-docker --glab-direct ~/repo`
- **THEN** `echo $GITLAB_TOKEN` inside the agent container prints `glpat_x`
- **AND** the token's host resolves normally inside the agent container

#### Scenario: --glab and --glab-direct together are rejected

- **WHEN** user runs `claude-docker --glab --glab-direct ~/repo`
- **THEN** `run.sh` exits non-zero with an error naming the conflicting flags
- **AND** no container or sidecar is started

#### Scenario: --tfe mounts host TFC credentials read-only

- **GIVEN** the host has a valid `~/.terraform.d/credentials.tfrc.json` with an `app.terraform.io` token entry
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** `/root/.terraform.d/credentials.tfrc.json` inside the container contains the host file's contents
- **AND** writes to `/root/.terraform.d/credentials.tfrc.json` from inside the container fail with EROFS

#### Scenario: --tfe forwards host TF_TOKEN_app_terraform_io

- **GIVEN** `TF_TOKEN_app_terraform_io=tfc_xyz` is exported in the host shell
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** `echo $TF_TOKEN_app_terraform_io` inside the container prints `tfc_xyz`

#### Scenario: --tfe is silent when neither file nor env var is set

- **GIVEN** the host has no `~/.terraform.d/credentials.tfrc.json` and no `TF_TOKEN_app_terraform_io` exported
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** the container starts without error
- **AND** `/root/.terraform.d/` inside the container is empty
- **AND** `echo $TF_TOKEN_app_terraform_io` inside the container is empty

#### Scenario: --tfe finds the Windows credentials file under %APPDATA%

- **GIVEN** `run.sh` runs under Git Bash on Windows
- **AND** `terraform login` wrote `%APPDATA%\terraform.d\credentials.tfrc.json` on the host
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** `/root/.terraform.d/credentials.tfrc.json` inside the container contains that file's contents, mounted read-only

#### Scenario: --az forwards the PAT and the org URL

- **GIVEN** `AZURE_DEVOPS_EXT_PAT=pat_x` and `AZURE_DEVOPS_ORG_URL=https://devops.example.com/DefaultCollection` are exported in the host shell
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** both variables are set inside the container with the host's values
- **AND** `az devops project list` inside the container targets `https://devops.example.com/DefaultCollection` without an `--org` argument

#### Scenario: --az mounts only the non-secret az config

- **GIVEN** the host has `~/.azure/azureProfile.json`, `~/.azure/clouds.config` and `~/.azure/msal_token_cache.json`
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** none of those files is present under `/root/.azure` inside the container
- **AND** `AZURE_DEVOPS_EXT_PAT` carries the host's value

#### Scenario: --az trusts the host REQUESTS_CA_BUNDLE

- **GIVEN** the host exports `CLAUDE_DOCKER_AZ_CA=~/.azure/tfs-ca.pem` naming a PEM CA certificate
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** the certificate is present in `/etc/ssl/certs/ca-certificates.crt` inside the container
- **AND** `az` resolves `REQUESTS_CA_BUNDLE` to `/etc/ssl/certs/ca-certificates.crt`, not the host path

#### Scenario: --az ignores the host REQUESTS_CA_BUNDLE

- **GIVEN** the host exports `REQUESTS_CA_BUNDLE` naming a PEM file and does not set `CLAUDE_DOCKER_AZ_CA`
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** no file is mounted at `/usr/local/share/ca-certificates/claude-docker-az.crt`

#### Scenario: --az with a missing REQUESTS_CA_BUNDLE fails loudly

- **GIVEN** the host exports `CLAUDE_DOCKER_AZ_CA=/nonexistent.pem`
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** `run.sh` exits 1 with an error naming the path and starts no container

### Requirement: In-container gh login persists only under --gh

Because macOS `gh` uses the Keychain (no host file to mount), the container SHALL support a fresh `gh auth login` whose resulting `~/.config/gh/` persists across runs via the existing `claude-code-root` volume. Access to that persisted state SHALL be gated on the current run actually needing it: `/root/.config/gh/` inside the container MUST appear empty (achieved by overlaying a tmpfs mask) unless the run is `--gh` with no host token found (in-container login is the remaining auth path) or `--gh-direct`. In particular, the mask SHALL stay ON when the auth proxy sidecar is active — the placeholder env token makes persisted login state unnecessary, and leaving it accessible would reintroduce a persisted in-container secret. When `--gh` is absent entirely, the mask applies as before. The same masking rule SHALL apply to `/root/.config/glab-cli/` when neither `--glab` nor `--glab-direct` is set, to `/root/.terraform.d/` when `--tfe` is not set (covering tokens written by an in-container `terraform login` that would otherwise persist via `claude-code-root`), and to `/root/.azure/` when `--az` is not set (covering `az devops configure` state and command logs naming organizations and projects).

The rule SHALL extend to `/root/.aws/` when `--aws` is not set. AWS has no
in-container `auth login` step, so it was omitted when this requirement was
written for the CLIs that do, but the persistence is identical: an `--aws`
session's derived credential cache is written under `/root`, and `/root` is the
shared volume. Under `--aws` the mask SHALL narrow to `/root/.aws/cli/cache/`
rather than covering the whole directory, so the read-only host mounts at
`/root/.aws/config` and `/root/.aws/sso/` remain visible to the session that
asked for them.

Masking SHALL NOT be conditional on any host-side path existing. A mask whose
presence depends on host state protects some machines and not others, and gives
the user no way to tell which.

#### Scenario: gh login survives container exit under --gh without a host token

- **GIVEN** the host has no GitHub token (no env vars, `gh auth token` fails)
- **AND** user completes `gh auth login` inside a container launched with `--gh`
- **WHEN** they exit and relaunch with `--gh` (host still has no token)
- **THEN** `gh auth status` reports "logged in" without re-prompting

#### Scenario: persisted gh login is masked while the sidecar is active

- **GIVEN** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **AND** the host has a GitHub token so the sidecar starts
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `/root/.config/gh/` inside the agent container is empty
- **AND** GitHub access works via the sidecar placeholder token

#### Scenario: prior gh login is hidden without --gh

- **GIVEN** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo` without `--gh`
- **THEN** `gh auth status` inside the container reports "not logged in"
- **AND** `/root/.config/gh/` inside the container is empty

#### Scenario: prior glab login is hidden without --glab

- **GIVEN** a prior container run completed `glab auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo` without `--glab`
- **THEN** `glab auth status` inside the container reports no authenticated host
- **AND** `/root/.config/glab-cli/` inside the container is empty

#### Scenario: prior terraform login is hidden without --tfe

- **GIVEN** a prior container run completed `terraform login app.terraform.io` (the resulting credentials file persists under `claude-code-root` in `/root/.terraform.d/`)
- **WHEN** user runs `claude-docker ~/repo` without `--tfe`
- **THEN** `/root/.terraform.d/` inside the container is empty
- **AND** no `credentials.tfrc.json` from the prior session is readable inside the container

#### Scenario: prior AWS credential cache is hidden without --aws

- **GIVEN** a prior container run used `--aws` and the AWS CLI cached STS credentials under `/root/.aws/cli/cache/` on the `claude-code-root` volume
- **WHEN** user runs `claude-docker ~/repo` without `--aws`
- **THEN** `/root/.aws/` inside the container is empty
- **AND** no cached credential from the prior session is readable inside the container

#### Scenario: an --aws session leaves no credential cache behind

- **GIVEN** the host has completed `aws sso login` and `~/.aws/sso/` exists
- **WHEN** user runs `claude-docker --aws ~/repo` and the AWS CLI derives and caches STS credentials
- **THEN** `/root/.aws/config` is readable inside that container
- **AND** on the next `claude-docker --aws ~/repo`, `/root/.aws/cli/cache/` is empty at session start

#### Scenario: prior az state is hidden without --az

- **GIVEN** a prior container run used `--az` and ran `az devops configure --defaults project=X` (state persisted under `/root/.azure/` in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo` without `--az`
- **THEN** `/root/.azure/` inside the container is empty

### Requirement: Custom model endpoint opt-in

Claude Code endpoint configuration SHALL NOT reach the container unless the user passes `--api` or `--api-direct`. Under either, `run.sh` SHALL forward each of `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`, and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` that is set on the host, by bare name (`-e NAME`) so no value appears on the wrapper's `docker run` argv. Under `--api`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY` SHALL be provided only to the per-session auth proxy sidecar (see capability `api-auth-proxy`). The agent container SHALL instead receive a sidecar `ANTHROPIC_BASE_URL` and `claude-docker-proxy` placeholders. Under `--api-direct`, those three SHALL also be forwarded by bare name and the model endpoint SHALL NOT be proxied. Passing `--api` and `--api-direct` together SHALL exit with an error. The modes SHALL surface as `api` and `api-direct` entries in `CLAUDE_DOCKER_FLAGS`.

Under `--api` or `--api-direct`, when neither `ANTHROPIC_AUTH_TOKEN` nor `ANTHROPIC_API_KEY` is set to a non-empty value on the host, `run.sh` SHALL exit with status 1 and an error naming both variables before starting any container. Without a gateway token, Claude Code sends the claude.ai OAuth token from the volume to `ANTHROPIC_BASE_URL` as its bearer.

Under `--api` or `--api-direct`, when the host sets `CLAUDE_DOCKER_API_CA` to a PEM file, `run.sh` SHALL mount it read-only at `/usr/local/share/ca-certificates/claude-docker-api.crt`, and the entrypoint SHALL install it into the system trust store as root before the privilege drop. When `CLAUDE_DOCKER_API_CA` is set but does not name a file, `run.sh` SHALL exit with an error before starting a container. `CLAUDE_DOCKER_API_CA` SHALL have no effect without `--api` or `--api-direct`. Under `--api`, the sidecar SHALL also trust it for the upstream connection. The certificate is installed into the system trust store, so it is trusted for every TLS connection in the container, not only the `--api` endpoint; the documentation SHALL say so.

Bedrock, Vertex, and Foundry provider selection (`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`) is out of scope for this opt-in.

#### Scenario: No flag means no endpoint config

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** neither variable is set inside the container

#### Scenario: --api routes through the sidecar

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** inside the agent container `ANTHROPIC_BASE_URL` points at the sidecar and `ANTHROPIC_AUTH_TOKEN` is `claude-docker-proxy`
- **AND** Claude Code requests reach `https://llm.internal` carrying `Authorization: Bearer tok`

#### Scenario: --api forwards endpoint config by name

- **GIVEN** the host exports `ANTHROPIC_AUTH_TOKEN=tok` and `ANTHROPIC_MODEL=gw-opus`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** `ANTHROPIC_MODEL` carries `gw-opus` inside the container
- **AND** the `docker run` argv of both the agent container and the sidecar contains no credential value

#### Scenario: --api-direct forwards endpoint config by name

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker --api-direct ~/repo`
- **THEN** both variables carry the host values inside the container
- **AND** the `docker run` argv contains `-e ANTHROPIC_AUTH_TOKEN` but not the token value

#### Scenario: --api and --api-direct together are rejected

- **WHEN** user runs `claude-docker --api --api-direct ~/repo`
- **THEN** `run.sh` exits non-zero with an error naming the conflicting flags
- **AND** no container or sidecar is started

#### Scenario: --api trusts a private gateway CA

- **GIVEN** the host sets `CLAUDE_DOCKER_API_CA` to a PEM CA certificate
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** the certificate is present in `/etc/ssl/certs/ca-certificates.crt` inside the container

#### Scenario: Missing CA file fails loudly

- **GIVEN** the host sets `CLAUDE_DOCKER_API_CA=/nonexistent.pem`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits non-zero with an error naming the path and starts no container

#### Scenario: --api without a gateway token fails closed

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and neither `ANTHROPIC_AUTH_TOKEN` nor `ANTHROPIC_API_KEY`, or only empty values for them
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits 1 with an error naming `ANTHROPIC_AUTH_TOKEN` and `ANTHROPIC_API_KEY`
- **AND** no container starts

#### Scenario: --api forwards gateway knobs

- **GIVEN** the host exports `ANTHROPIC_AUTH_TOKEN=tok`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1` and `CLAUDE_CODE_MAX_CONTEXT_TOKENS=1000000`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** both knobs carry the host values inside the container
- **AND** without `--api` neither is set inside the container

### Requirement: Git credential helper per forge host

So that git can fetch and push over HTTPS with the token a forge flag already forwards, `run.sh` SHALL give git a credential helper for each of these flags, scoped to that forge's host:

- `--gh-direct`: `credential.https://github.com.helper` set to `gh auth git-credential`. `--gh` adds none: the sidecar injects auth for `github.com`.
- `--glab-direct`: `credential.https://<host>.helper` set to `glab auth git-credential`, where `<host>` is `GITLAB_HOST` after token discovery (keeping any port), else `gitlab.com`. `--glab` adds none: the sidecar injects auth on the proxied GitLab host's git paths.
- `--az`: `credential.https://<host>.helper` for the host of `AZURE_DEVOPS_ORG_URL`, else `dev.azure.com`, set to a helper that answers `get` with `AZURE_DEVOPS_EXT_PAT` read from the container env when git calls it. The PAT SHALL NOT appear in argv or in the helper string.

Each helper SHALL be scoped to its host so git never offers that token to another host. The config SHALL be passed as `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` env, on one list with any other such entries (`safe.directory` on Git Bash), so nothing is written to `~/.gitconfig`. `run.sh` SHALL NOT rewrite SSH remotes.

#### Scenario: HTTPS push works under --glab

- **GIVEN** a workspace whose `origin` is `https://gitlab.example.com/grp/repo.git` and a GitLab token for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/repo` on a fresh volume and runs `git push` inside the container
- **THEN** git authenticates through the sidecar without a prompt
- **AND** no `GIT_CONFIG_*` credential helper is passed for `gitlab.example.com`

#### Scenario: HTTPS push works under --glab-direct

- **GIVEN** a workspace whose `origin` is `https://gitlab.example.com/grp/repo.git` and a GitLab token for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab-direct ~/repo` on a fresh volume and runs `git push` inside the container
- **THEN** git authenticates with the forwarded token through `glab auth git-credential` without a prompt

#### Scenario: A token is not offered to another host

- **GIVEN** `claude-docker --az ~/repo` with `AZURE_DEVOPS_ORG_URL=https://dev.azure.com/org`
- **WHEN** git asks for credentials for `https://other.example.com`
- **THEN** the PAT helper does not answer and the PAT is not sent

#### Scenario: No forge flag, no helper

- **WHEN** user runs `claude-docker ~/repo` on a Linux or macOS host
- **THEN** no `GIT_CONFIG_*` env is passed to the container
