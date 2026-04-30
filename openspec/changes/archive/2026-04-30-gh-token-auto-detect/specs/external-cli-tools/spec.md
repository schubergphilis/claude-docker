## MODIFIED Requirements

### Requirement: Credentials opt-in

Host credentials (files or env vars) SHALL NOT reach the container unless the
user explicitly opts in per-run. `run.sh` defaults to no credential mounts and
no token env forwarding. Opt-ins are granted via dedicated flags:

- `--aws`: mount `~/.aws/config` at `/root/.aws/config:ro` and, when present,
  `~/.aws/sso/` at `/root/.aws/sso:ro`; forward `AWS_PROFILE`, `AWS_REGION`,
  `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` when set.
- `--gh`: forward `GH_TOKEN` or `GITHUB_TOKEN` when set on the host. If neither
  is set, `run.sh` SHALL attempt to retrieve the active token by running
  `gh auth token` on the host and forward the result as `GH_TOKEN`. If `gh` is
  not on the host PATH or the command fails, `run.sh` SHALL continue silently
  without a token.
- `--glab`: mount the platform-appropriate glab config dir at
  `/root/.config/glab-cli:ro`; forward `GITLAB_TOKEN` when set on the host.

All credential bind-mounts SHALL be read-only. `~/.aws/credentials` and
`~/.aws/cli/cache/` SHALL NEVER be mounted, even under `--aws`.

#### Scenario: No flags means no credentials

- **GIVEN** host has `~/.aws/config`, `~/.config/glab-cli/config.yml`, and `GH_TOKEN=ghp_x` exported
- **AND** a prior container run completed `gh auth login`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `/root/.aws/` does not exist inside the container
- **AND** `/root/.config/glab-cli/` is empty inside the container
- **AND** `echo $GH_TOKEN` inside the container is empty
- **AND** `gh auth status` inside the container reports "not logged in"

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
