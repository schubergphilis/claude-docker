# Spec Delta

## MODIFIED Requirements

### Requirement: gh, glab, aws v2 installed

The container image SHALL ship with `gh`, `glab`, `aws` (v2) and the Docker CLI (`docker`, with the `compose` and `buildx` plugins; client only, no daemon) on the default PATH, built arch-aware for both `amd64` and `arm64`.

#### Scenario: CLIs present

- **WHEN** the container launches
- **THEN** `gh --version`, `glab --version`, `aws --version`, `docker --version`, `docker compose version` and `docker buildx version` all succeed

#### Scenario: Builds on Apple Silicon

- **WHEN** `docker build -t claude-code:local ~/claude-docker` runs on arm64
- **THEN** the build succeeds and no CLI fails with exec-format error
