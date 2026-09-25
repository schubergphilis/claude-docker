## ADDED Requirements

### Requirement: az with the azure-devops extension installed

The container image SHALL ship an `az` command on the default PATH that runs the `azure-devops` extension (`az devops`, `az repos`, `az boards`, `az pipelines`) on both `amd64` and `arm64`. It SHALL be built from `azure-cli-core` plus the extension, not the full `azure-cli` distribution. `azure-cli-core` SHALL be version-pinned via `pins/az.env`; the extension SHALL be installed from the wheel URL recorded in `pins/azure-devops.env` after verifying it against the sha256 recorded there, not via the unpinned extension index. The Python runtime and all az files SHALL live outside `/root` and SHALL NOT add a `python` / `python3` to the default PATH. The build SHALL fail if the extension does not load.

#### Scenario: az devops present

- **WHEN** the container launches
- **THEN** `az --version` reports the pinned `azure-cli-core` version and the pinned `azure-devops` extension version
- **AND** `az devops -h` succeeds

#### Scenario: build fails on a tampered extension wheel

- **GIVEN** a build where the downloaded wheel does not match `AZURE_DEVOPS_SHA256`
- **WHEN** the Dockerfile runs `sha256sum -c`
- **THEN** the build fails before anything is installed

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
- `--glab`: mount the platform-appropriate glab config dir — `~/Library/Application Support/glab-cli` on macOS, `~/.config/glab-cli` on Linux — at `/root/.config/glab-cli:ro`; forward `GITLAB_TOKEN` when set on the host.
- `--tfe`: when present on the host, mount `~/.terraform.d/credentials.tfrc.json` at `/root/.terraform.d/credentials.tfrc.json:ro`; forward `TF_TOKEN_app_terraform_io` when set on the host. Targets `app.terraform.io` (HCP Terraform); self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are out of scope for this opt-in.
- `--az`: forward `AZURE_DEVOPS_EXT_PAT` and `AZURE_DEVOPS_ORG_URL` when set on the host; when present on the host, mount `~/.azure/azureProfile.json` at `/root/.azure/azureProfile.json:ro` and `~/.azure/clouds.config` at `/root/.azure/clouds.config:ro`. `AZURE_DEVOPS_ORG_URL` SHALL be the only source of the Azure DevOps hostname — nothing SHALL assume `dev.azure.com`, so Azure DevOps Server (on-prem, custom hostname) works the same as Services. `run.sh` SHALL NOT attempt host-side PAT discovery (`az` has no command that prints a usable PAT). Targets the `azure-devops` extension only; general Azure resource management and its credentials (`ARM_*`, `AZURE_CLIENT_SECRET`, service principals) are out of scope for this opt-in.

All credential bind-mounts SHALL be read-only so a compromised container cannot rewrite host config or tokens. `~/.aws/credentials` and `~/.aws/cli/cache/` SHALL NEVER be mounted, even under `--aws`. Likewise nothing under `~/.azure/` other than `azureProfile.json` and `clouds.config` SHALL be mounted under `--az` — in particular never the Azure token caches `msal_token_cache.json` or `accessTokens.json`.

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
- **THEN** `/root/.azure/azureProfile.json` and `/root/.azure/clouds.config` are readable inside the container and writes to them fail with EROFS
- **AND** `/root/.azure/msal_token_cache.json` is not present inside the container

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
