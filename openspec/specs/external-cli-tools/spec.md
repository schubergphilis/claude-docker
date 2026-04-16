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

### Requirement: Host credential bind-mounts for file-based CLIs

When the host has a glab config directory or `~/.aws/`, `run.sh` SHALL bind-mount each into the container read-write. The glab source path is platform-aware: `~/Library/Application Support/glab-cli` on macOS, `~/.config/glab-cli` on Linux. Both target `/root/.config/glab-cli` in the container.

#### Scenario: glab inherits host token

- **GIVEN** the host has a valid `~/.config/glab-cli/config.yml`
- **WHEN** user launches the container
- **THEN** `glab auth status` reports "logged in" without prompting

#### Scenario: aws inherits host credentials

- **GIVEN** `~/.aws/credentials` is configured on the host
- **WHEN** user launches the container
- **THEN** `aws sts get-caller-identity` returns the host's identity

### Requirement: Auth env var forwarding

`run.sh` SHALL forward `GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN`, `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` into the container when set on the host.

#### Scenario: Host token forwarded

- **GIVEN** `GH_TOKEN=ghp_x` is exported in the host shell
- **WHEN** user launches the container
- **THEN** `echo $GH_TOKEN` inside the container prints `ghp_x`

### Requirement: In-container gh login persists

Because macOS `gh` uses the Keychain (no host file to mount), the container SHALL support a fresh `gh auth login` whose resulting `~/.config/gh/` persists across runs via the existing `claude-code-root` volume.

#### Scenario: gh login survives container exit

- **GIVEN** user completes `gh auth login` inside a container
- **WHEN** they exit and relaunch
- **THEN** `gh auth status` reports "logged in" without re-prompting
