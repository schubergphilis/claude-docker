## ADDED Requirements

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

## MODIFIED Requirements

### Requirement: Credentials opt-in

Host credentials (files or env vars) SHALL NOT reach the container unless the user explicitly opts in per-run. `run.sh` defaults to no credential mounts and no token env forwarding. Opt-ins are granted via dedicated flags:

- `--aws`: mount `~/.aws/config` at `/root/.aws/config:ro` and, when present, `~/.aws/sso/` at `/root/.aws/sso:ro`; forward `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` when set on the host.
- `--gh`: forward `GH_TOKEN` or `GITHUB_TOKEN` when set on the host. If neither
  is set, `run.sh` SHALL attempt to retrieve the active token by running
  `gh auth token` on the host and forward the result as `GH_TOKEN`. If `gh` is
  not on the host PATH or the command fails, `run.sh` SHALL continue silently
  without a token.
- `--glab`: mount the platform-appropriate glab config dir — `~/Library/Application Support/glab-cli` on macOS, `~/.config/glab-cli` on Linux — at `/root/.config/glab-cli:ro`; forward `GITLAB_TOKEN` when set on the host.
- `--tfe`: when present on the host, mount `~/.terraform.d/credentials.tfrc.json` at `/root/.terraform.d/credentials.tfrc.json:ro`; forward `TF_TOKEN_app_terraform_io` when set on the host. Targets `app.terraform.io` (HCP Terraform); self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are out of scope for this opt-in.

All credential bind-mounts SHALL be read-only so a compromised container cannot rewrite host config or tokens. `~/.aws/credentials` and `~/.aws/cli/cache/` SHALL NEVER be mounted, even under `--aws`.

#### Scenario: No flags means no credentials

- **GIVEN** host has `~/.aws/config`, `~/.config/glab-cli/config.yml`, `~/.terraform.d/credentials.tfrc.json`, and `GH_TOKEN=ghp_x` and `TF_TOKEN_app_terraform_io=tfc_x` exported
- **AND** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `/root/.aws/` does not exist inside the container
- **AND** `/root/.config/glab-cli/` is empty inside the container
- **AND** `/root/.terraform.d/` is empty inside the container
- **AND** `echo $GH_TOKEN` inside the container is empty
- **AND** `echo $TF_TOKEN_app_terraform_io` inside the container is empty
- **AND** `gh auth status` inside the container reports "not logged in"

#### Scenario: --aws grants scoped AWS access

- **GIVEN** the host has completed `aws sso login --profile X` and exports `AWS_PROFILE=X`
- **WHEN** user runs `claude-docker --aws ~/repo`
- **THEN** `aws sts get-caller-identity` inside the container returns the host's identity
- **AND** `~/.aws/credentials` is not present inside the container
- **AND** writes to `/root/.aws/` from inside the container fail with EROFS

#### Scenario: --glab grants read-only token access

- **GIVEN** the host has a valid `~/.config/glab-cli/config.yml`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `glab auth status` reports "logged in" without prompting
- **AND** writes to `/root/.config/glab-cli/` from inside the container fail with EROFS

#### Scenario: --gh forwards host env token

- **GIVEN** `GH_TOKEN=ghp_x` is exported in the host shell
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `echo $GH_TOKEN` inside the container prints `ghp_x`

#### Scenario: --gh falls back to gh auth token

- **GIVEN** neither `GH_TOKEN` nor `GITHUB_TOKEN` is set in the host shell
- **AND** the host has `gh` on PATH and the user is authenticated (`gh auth status` succeeds)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `echo $GH_TOKEN` inside the container prints the token returned by `gh auth token`

#### Scenario: --gh is silent when gh is unavailable

- **GIVEN** neither `GH_TOKEN` nor `GITHUB_TOKEN` is set in the host shell
- **AND** `gh` is not on the host PATH (or `gh auth token` exits non-zero)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** the container starts without a `GH_TOKEN` env var and no error is printed

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

### Requirement: In-container gh login persists only under --gh

Because macOS `gh` uses the Keychain (no host file to mount), the container SHALL support a fresh `gh auth login` whose resulting `~/.config/gh/` persists across runs via the existing `claude-code-root` volume. Access to that persisted state SHALL be gated on `--gh` being passed in the current run: when `--gh` is not set, `/root/.config/gh/` inside the container MUST appear empty (achieved by overlaying a tmpfs mask) so a prior login cannot grant credentials to a session the user didn't opt in to. The same masking rule SHALL apply to `/root/.config/glab-cli/` when `--glab` is not set, and to `/root/.terraform.d/` when `--tfe` is not set (covering tokens written by an in-container `terraform login` that would otherwise persist via `claude-code-root`).

#### Scenario: gh login survives container exit under --gh

- **GIVEN** user completes `gh auth login` inside a container launched with `--gh`
- **WHEN** they exit and relaunch with `--gh`
- **THEN** `gh auth status` reports "logged in" without re-prompting

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
