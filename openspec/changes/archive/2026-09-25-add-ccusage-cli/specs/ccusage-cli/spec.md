## Purpose

Ship the `ccusage` CLI inside the container image at the repo's pinned version, so a host statusline script that shows Claude Code token usage or spend through `ccusage` renders the same segment in the container. It needs no host install, credentials, or extra `run.sh` surface.

## ADDED Requirements

### Requirement: ccusage CLI installed at the pinned version

The container image SHALL ship the `ccusage` CLI (npm package `ccusage`) on the default PATH at the version recorded in `pins/ccusage.env`, and SHALL report that same version at runtime.

`ccusage` is a node launcher that runs a per-architecture native binary from an optional dependency (`@ccusage/ccusage-linux-x64` or `@ccusage/ccusage-linux-arm64`). npm installs that binary without its executable bit, and the launcher tries to `chmod` it on first use. The container runs `ccusage` as the non-root host UID, which cannot `chmod` a root-owned file. The build SHALL therefore set the executable bit on the native binary, and SHALL fail if `ccusage --version` does not report the pinned version.

This requirement binds `ccusage` to mechanisms owned elsewhere rather than restating them: how the pin fragment is resolved, written, and consumed by the build is owned by `version-pin-refresh`, and the `--ignore-scripts` hygiene of the npm invocation that installs it is owned by `package-managers`.

#### Scenario: CLI present at the pinned version

- **WHEN** the container launches
- **THEN** `ccusage --version` succeeds as the host UID
- **AND** it prints `ccusage <version>`, where `<version>` is the `CCUSAGE_VERSION` value recorded in `pins/ccusage.env`
- **AND** the CLI resolves to a path inside the image, not to a host mount

### Requirement: No credential plumbing or run.sh surface

The `ccusage` CLI has no authentication requirements. Its presence SHALL NOT add any `run.sh` flag, bind-mount, env-var forward, or volume, and SHALL NOT alter any credential-handling behaviour defined by `external-cli-tools`.

`ccusage` reads session transcripts from the container's own `/root/.claude/projects/`, which lives in the persistent home volume. Host transcripts are not forwarded, so reported usage covers container sessions only. The documentation SHALL say so.

#### Scenario: No new run.sh surface

- **WHEN** `claude-docker --help` is invoked
- **THEN** no ccusage-specific flag appears in the output
- **AND** neither `run.sh` nor `entrypoint.sh` contains a ccusage-specific mount, env-var forward, or volume

#### Scenario: Usage reflects container sessions only

- **GIVEN** the user has Claude Code sessions on the host and in the container
- **WHEN** `ccusage monthly` runs inside the container
- **THEN** it reports usage from the container's transcripts only
