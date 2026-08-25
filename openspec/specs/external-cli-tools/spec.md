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

### Requirement: In-container gh login persists only under --gh

Because macOS `gh` uses the Keychain (no host file to mount), the container SHALL support a fresh `gh auth login` whose resulting `~/.config/gh/` persists across runs via the existing `claude-code-root` volume. Access to that persisted state SHALL be gated on the current run actually needing it: `/root/.config/gh/` inside the container MUST appear empty (achieved by overlaying a tmpfs mask) unless the run is `--gh` with no host token found (in-container login is the remaining auth path) or `--gh-direct`. In particular, the mask SHALL stay ON when the auth proxy sidecar is active — the placeholder env token makes persisted login state unnecessary, and leaving it accessible would reintroduce a persisted in-container secret. When `--gh` is absent entirely, the mask applies as before. The same masking rule SHALL apply to `/root/.config/glab-cli/` when `--glab` is not set, and to `/root/.terraform.d/` when `--tfe` is not set (covering tokens written by an in-container `terraform login` that would otherwise persist via `claude-code-root`).

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

