# openspec-cli Specification

## Purpose

Ship the `openspec` CLI inside the container image at the repo's pinned version, so spec-driven work — reading `openspec/specs/`, drafting and validating changes — runs out of the box with no host install, no credentials, and no host state.

## Requirements

### Requirement: openspec CLI installed at the pinned version

The container image SHALL ship the `openspec` CLI (`@fission-ai/openspec`) on the default PATH at the version recorded in `pins/openspec.env`, and SHALL report that same version at runtime.

This requirement binds `openspec` to two mechanisms owned elsewhere rather than restating them: how the pin fragment is resolved, written, and consumed by the build is owned by `version-pin-refresh` (including that the Dockerfile carries no literal version for any automated tool), and the `--ignore-scripts` hygiene of the npm invocation that installs it is owned by `package-managers`.

#### Scenario: CLI present at the pinned version

- **WHEN** the container launches
- **THEN** `openspec --version` succeeds
- **AND** it prints the `OPENSPEC_VERSION` value recorded in `pins/openspec.env`
- **AND** the CLI resolves to a path inside the image, not to a host mount

### Requirement: No credential plumbing or run.sh surface

The `openspec` CLI has no authentication or host-state requirements. Its presence SHALL NOT add any `run.sh` flag, bind-mount, env-var forward, or volume, and SHALL NOT alter any credential-handling behaviour defined by `external-cli-tools`.

#### Scenario: No new run.sh surface

- **WHEN** `claude-docker --help` is invoked
- **THEN** no openspec-specific flag appears in the output
- **AND** neither `run.sh` nor `entrypoint.sh` contains an openspec-specific mount, env-var forward, or volume, so the set observed inside the container is identical to an image built without the CLI

#### Scenario: openspec works with zero host state

- **GIVEN** the host has no `openspec` install and no openspec-related env vars or config files
- **WHEN** the user runs `claude-docker ~/repo` and, inside the container, `cd /workspaces/repo && openspec --help`
- **THEN** `openspec --help` succeeds
