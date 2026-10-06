# external-cli-tools

## Purpose

Provide `gh`, `glab`, and AWS CLI v2 inside the container with minimal re-auth friction, using host credential passthrough where the tool's macOS storage is file-based and in-container persistence otherwise.

## Requirements

### Requirement: gh, glab, aws v2 installed

The container image SHALL ship with `gh`, `glab`, and `aws` (v2) on the default PATH, built arch-aware for both `amd64` and `arm64`.

#### Scenario: CLIs present

- **WHEN** the container launches
- **THEN** `gh --version`, `glab --version`, and `aws --version` all succeed

#### Scenario: Builds on Apple Silicon

- **WHEN** `docker build -t claude-code:local ~/claude-docker` runs on arm64
- **THEN** the build succeeds and no CLI fails with exec-format error

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
- `--glab`: mount the platform-appropriate glab config dir — `~/Library/Application Support/glab-cli` on macOS, `~/.config/glab-cli` on Linux — at `/root/.config/glab-cli:ro`; forward `GITLAB_TOKEN` and `GITLAB_HOST` when set on the host. If `GITLAB_TOKEN` is not set, `run.sh` SHALL attempt to retrieve the host glab token by running `glab config get token --host <host>` for each candidate host in turn, stopping at the first that returns a token. When `GITLAB_HOST` is set, its host (with any port) is the only candidate. Otherwise the candidates are, in order, the host of the first workspace's `remote.origin.url` (read as a file from the `config` in the repository's common git dir, `git rev-parse --git-common-dir`, so a worktree or submodule workspace resolves to its main repository's or module's config; skipped when `.git` or that `config` is a symlink or absent, or when the common git dir can't be resolved) and the host of glab's default host (`glab config get host`; `gitlab.com` if empty). A host keeps its port, except for an `ssh://` or scp-style (`user@host:path`) remote, where the port is the SSH port and SHALL be dropped. A host already tried SHALL NOT be tried or named again. That command also reads tokens glab stored in the OS keyring. A discovered token SHALL be forwarded as `GITLAB_TOKEN` by bare name so it never appears in argv. If `glab` is not on the host PATH or returns no token for any candidate, `run.sh` SHALL continue without one and print a one-line warning to stderr naming the hosts tried and the `GITLAB_TOKEN` / `GITLAB_HOST` remedies; the warning SHALL NOT contain any token value.
- `--tfe`: when present on the host, mount `~/.terraform.d/credentials.tfrc.json` at `/root/.terraform.d/credentials.tfrc.json:ro`; forward `TF_TOKEN_app_terraform_io` when set on the host. Targets `app.terraform.io` (HCP Terraform); self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are out of scope for this opt-in.
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

#### Scenario: --glab falls back to the host glab token

- **GIVEN** `GITLAB_TOKEN` is not set on the host and `GITLAB_HOST=https://gitlab.example.com` is
- **AND** host `glab auth login` stored a token for `gitlab.example.com`, in `config.yml` or the OS keyring
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the container receives that token as `GITLAB_TOKEN`, and `GITLAB_HOST`
- **AND** neither token nor host value appears in the `docker run` argv

#### Scenario: --glab discovers a keyring-held token

- **GIVEN** `GITLAB_TOKEN` is not set on the host
- **AND** host glab's `config.yml` has `use_keyring: true` and no `token` for the default host, the token living only in the OS keyring
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the token returned by host `glab config get token --host <host>` is forwarded as `GITLAB_TOKEN`

#### Scenario: --glab keeps an explicit GITLAB_TOKEN

- **GIVEN** `GITLAB_TOKEN` is set on the host
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** host `glab` is not asked for a token and the container receives the host's `GITLAB_TOKEN`

#### Scenario: --glab discovers the token for the workspace remote's host

- **GIVEN** neither `GITLAB_TOKEN` nor `GITLAB_HOST` is set on the host
- **AND** glab's default host is `gitlab.com`, but `~/repo`'s `origin` is `git@gitlab.example.com:group/project.git`
- **AND** host glab holds a token only for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the container receives that token as `GITLAB_TOKEN`

#### Scenario: --glab discovers the origin host from a worktree workspace

- **GIVEN** neither `GITLAB_TOKEN` nor `GITLAB_HOST` is set on the host
- **AND** `~/wt` is a git worktree (its `.git` is a pointer file) of a repository whose `origin` is `git@gitlab.example.com:group/project.git`
- **AND** host glab holds a token only for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/wt`
- **THEN** the container receives that token as `GITLAB_TOKEN`

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

Because macOS `gh` uses the Keychain (no host file to mount), the container SHALL support a fresh `gh auth login` whose resulting `~/.config/gh/` persists across runs via the existing `claude-code-root` volume. Access to that persisted state SHALL be gated on the current run actually needing it: `/root/.config/gh/` inside the container MUST appear empty (achieved by overlaying a tmpfs mask) unless the run is `--gh` with no host token found (in-container login is the remaining auth path) or `--gh-direct`. In particular, the mask SHALL stay ON when the auth proxy sidecar is active — the placeholder env token makes persisted login state unnecessary, and leaving it accessible would reintroduce a persisted in-container secret. When `--gh` is absent entirely, the mask applies as before. The same masking rule SHALL apply to `/root/.config/glab-cli/` when `--glab` is not set, to `/root/.terraform.d/` when `--tfe` is not set (covering tokens written by an in-container `terraform login` that would otherwise persist via `claude-code-root`), and to `/root/.azure/` when `--az` is not set (covering `az devops configure` state and command logs naming organizations and projects).

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

### Requirement: git-lfs installed and LFS filters registered

The container image SHALL ship with `git-lfs` on the default PATH so that git
operations on LFS-backed repositories succeed instead of aborting on a missing
filter program. The image SHALL register the LFS filters system-wide at build
time (e.g. `git lfs install --system --skip-repo`) so that LFS smudge/clean
filtering works whether the host kept its filter configuration repo-local — in
which case `run.sh` copies it into the container's `.git/config` overlay — or
only in the host's global `~/.gitconfig`, which the container does NOT inherit
(only `user.name` / `user.email` are forwarded). The `git-lfs` package MAY be
installed unpinned from the distribution archive, consistent with the existing
`git` install.

#### Scenario: git-lfs present on PATH

- **WHEN** the container launches
- **THEN** `git lfs version` succeeds
- **AND** `git config --system --get filter.lfs.process` reports `git-lfs filter-process`

#### Scenario: worktree creation on an LFS repo no longer aborts

- **GIVEN** a mounted repository whose `.git/config` declares the `lfs` filter with `filter.lfs.required = true` (as carried into the container by the existing config overlay)
- **WHEN** a worktree is created inside the container (e.g. `git worktree add .claude/worktrees/feature -b feature`)
- **THEN** the checkout populating the new worktree completes without the `git: 'lfs' is not a git command` / `external filter 'git-lfs filter-process' failed` error
- **AND** the container session starts normally

#### Scenario: LFS filtering works when host config was global-only

- **GIVEN** a repository tracking files via `.gitattributes` with `filter=lfs` whose `filter.lfs.*` definitions existed only in the host's global `~/.gitconfig` (and therefore are not present in the per-repo `.git/config` overlay)
- **WHEN** git inside the container checks out an LFS-tracked file
- **THEN** the system-registered LFS filter is invoked rather than the file being passed through as an unsmudged pointer

### Requirement: tfenv installed and version-pinned

The container image SHALL ship with `tfenv` on the default PATH so users can fetch a project-pinned `terraform` binary on demand. The `tfenv` install SHALL pin the upstream version via a Dockerfile `ARG` and verify the downloaded artifact against an `ARG`-pinned sha256 before installation. The pinned hash SHALL live in version control, not be fetched from the source URL at build time. The image SHALL NOT pre-install any `terraform` binary version; version selection is the project's responsibility, exercised at runtime via `tfenv install` (typically driven by a `.terraform-version` file in the workspace). The `terraform` dispatcher shim that tfenv ships (a bash script, not a terraform binary) MAY be on PATH so that `terraform <subcommand>` works after `tfenv install` without further PATH manipulation.

#### Scenario: tfenv present on PATH, no terraform binary version installed

- **WHEN** the container launches
- **THEN** `tfenv --version` succeeds
- **AND** running `terraform version` before any `tfenv install` exits non-zero (the dispatcher reports no version available, and no real terraform binary exists under tfenv's versions directory)

#### Scenario: build fails on tampered tfenv archive

- **GIVEN** a build where the tfenv source archive does not match the pinned `TFENV_SHA256` ARG
- **WHEN** the Dockerfile runs `sha256sum -c`
- **THEN** the build fails with a non-zero exit code before installation
- **AND** no `tfenv` binary is installed onto the default PATH

#### Scenario: version bumps require sha256 bumps in the same commit

- **WHEN** a contributor changes `TFENV_VERSION` without updating `TFENV_SHA256`
- **THEN** the next build fails sha256 verification
- **AND** the failure surfaces in CI before merge

#### Scenario: tfenv install fetches a project-pinned terraform at runtime

- **GIVEN** a workspace containing a `.terraform-version` file with the contents `1.9.5`
- **WHEN** the user runs `tfenv install` inside the container
- **THEN** tfenv downloads terraform 1.9.5 from `releases.hashicorp.com` and installs it
- **AND** subsequent `terraform version` invocations report `1.9.5`

### Requirement: Custom model endpoint opt-in

Claude Code endpoint configuration SHALL NOT reach the container unless the user passes `--api`. Under `--api`, `run.sh` SHALL forward each of `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, `ANTHROPIC_SMALL_FAST_MODEL`, `CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS`, and `CLAUDE_CODE_MAX_CONTEXT_TOKENS` that is set on the host, by bare name (`-e NAME`) so no value appears on the wrapper's `docker run` argv. The mode SHALL surface as an `api` entry in `CLAUDE_DOCKER_FLAGS`.

Under `--api`, when neither `ANTHROPIC_AUTH_TOKEN` nor `ANTHROPIC_API_KEY` is set to a non-empty value on the host, `run.sh` SHALL exit with status 1 and an error naming both variables before starting any container. Without a gateway token, Claude Code sends the claude.ai OAuth token from the volume to `ANTHROPIC_BASE_URL` as its bearer.

Under `--api`, when the host sets `CLAUDE_DOCKER_API_CA` to a PEM file, `run.sh` SHALL mount it read-only at `/usr/local/share/ca-certificates/claude-docker-api.crt`, and the entrypoint SHALL install it into the system trust store as root before the privilege drop. When `CLAUDE_DOCKER_API_CA` is set but does not name a file, `run.sh` SHALL exit with an error before starting a container. `CLAUDE_DOCKER_API_CA` SHALL have no effect without `--api`. The certificate is installed into the system trust store, so it is trusted for every TLS connection in the container, not only the `--api` endpoint; the documentation SHALL say so.

Bedrock, Vertex, and Foundry provider selection (`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`) is out of scope for this opt-in.

#### Scenario: No flag means no endpoint config

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** neither variable is set inside the container

#### Scenario: --api forwards endpoint config by name

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** both variables carry the host values inside the container
- **AND** the `docker run` argv contains `-e ANTHROPIC_AUTH_TOKEN` but not the token value

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

### Requirement: az with the azure-devops extension installed

The container image SHALL ship an `az` command on the default PATH that runs the `azure-devops` extension (`az devops`, `az repos`, `az boards`, `az pipelines`) on both `amd64` and `arm64`. It SHALL be built from `azure-cli-core` plus the extension, not the full `azure-cli` distribution. `azure-cli-core` SHALL be version-pinned via `pins/az.env`, and it and every transitive dependency SHALL be installed with `--require-hashes` from the hash-locked `pins/az-requirements.txt`; the build SHALL fail if the lock does not pin the `pins/az.env` version. the extension SHALL be installed from the wheel URL recorded in `pins/azure-devops.env` after verifying it against the sha256 recorded there, not via the unpinned extension index. The Python runtime and all az files SHALL live outside `/root` and SHALL NOT add a `python` / `python3` to the default PATH. The build SHALL fail if the extension does not load. The `az` wrapper SHALL set `AZURE_CORE_COLLECT_TELEMETRY=no`.

#### Scenario: az devops present

- **WHEN** the container launches
- **THEN** `az --version` reports the pinned `azure-cli-core` version and the pinned `azure-devops` extension version
- **AND** `az devops -h` succeeds

#### Scenario: build fails on a tampered extension wheel

- **GIVEN** a build where the downloaded wheel does not match `AZURE_DEVOPS_SHA256`
- **WHEN** the Dockerfile runs `sha256sum -c`
- **THEN** the build fails before anything is installed

#### Scenario: az deps are hash-locked

- **GIVEN** `pins/az-requirements.txt` lists a dependency without a `--hash`, or pins an `azure-cli-core` version other than `pins/az.env`'s
- **WHEN** the image is built
- **THEN** the build fails
