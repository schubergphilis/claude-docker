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
- `--gh`: forward `GH_TOKEN` or `GITHUB_TOKEN` when set on the host. If neither
  is set, `run.sh` SHALL attempt to retrieve the active token by running
  `gh auth token` on the host and forward the result as `GH_TOKEN`. If `gh` is
  not on the host PATH or the command fails, `run.sh` SHALL continue silently
  without a token.
- `--glab`: mount the platform-appropriate glab config dir — `~/Library/Application Support/glab-cli` on macOS, `~/.config/glab-cli` on Linux — at `/root/.config/glab-cli:ro`; forward `GITLAB_TOKEN` when set on the host.

All credential bind-mounts SHALL be read-only so a compromised container cannot rewrite host config or tokens. `~/.aws/credentials` and `~/.aws/cli/cache/` SHALL NEVER be mounted, even under `--aws`.

#### Scenario: No flags means no credentials

- **GIVEN** host has `~/.aws/config`, `~/.config/glab-cli/config.yml`, and `GH_TOKEN=ghp_x` exported
- **AND** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `/root/.aws/` does not exist inside the container
- **AND** `/root/.config/glab-cli/` is empty inside the container
- **AND** `echo $GH_TOKEN` inside the container is empty
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

### Requirement: In-container gh login persists only under --gh

Because macOS `gh` uses the Keychain (no host file to mount), the container SHALL support a fresh `gh auth login` whose resulting `~/.config/gh/` persists across runs via the existing `claude-code-root` volume. Access to that persisted state SHALL be gated on `--gh` being passed in the current run: when `--gh` is not set, `/root/.config/gh/` inside the container MUST appear empty (achieved by overlaying a tmpfs mask) so a prior login cannot grant credentials to a session the user didn't opt in to. The same masking rule SHALL apply to `/root/.config/glab-cli/` when `--glab` is not set.

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

