# Spec Delta

## MODIFIED Requirements

### Requirement: Variadic workspace args

`run.sh` SHALL accept N host directory paths as positional arguments and mount each at `/workspaces/<basename>` in the container. With no workspace args, `$PWD` is mounted. A `--ro=PATH` flag counts as a workspace arg, so `$PWD` is the default only when neither positional workspaces nor `--ro=PATH` flags are given.

#### Scenario: Multiple dirs mounted

- **WHEN** user runs `~/claude-docker/run.sh ~/repo-a ~/repo-b`
- **THEN** `/workspaces/repo-a` and `/workspaces/repo-b` are both present and writable

#### Scenario: No args defaults to PWD

- **WHEN** user runs `~/claude-docker/run.sh` from `~/repo-a`
- **THEN** `~/repo-a` is mounted at `/workspaces/repo-a`

#### Scenario: --ro=PATH replaces the PWD default

- **WHEN** user runs `claude-docker --ro=~/shared` from `~/repo-a`
- **THEN** only `~/shared` is mounted, read-only at `/workspaces/shared`, and it is the working directory

### Requirement: Reject basename collisions

When two or more workspace arguments resolve to the same basename, `run.sh` SHALL fail fast with a non-zero exit and an error identifying both host paths, rather than silently letting Docker drop all but the last mount. When they are the same path (for example passed both as `PATH` and as `--ro=PATH`), the error SHALL say the workspace was given more than once and how to pass it read-write or read-only. When they are the same directory through a symlink, one read-write and one read-only, `run.sh` SHALL fail with an error naming both paths, because the read-only mount would protect nothing.

#### Scenario: Colliding basenames error out

- **WHEN** user runs `claude-docker ~/client-a/api ~/client-b/api`
- **THEN** `run.sh` exits non-zero with a message naming both host paths
- **AND** no container is started

#### Scenario: Same directory passed twice

- **WHEN** user runs `claude-docker ~/repo --ro=~/repo`
- **THEN** `run.sh` exits non-zero with a message that `~/repo` is given more than once, naming `PATH` and `--ro=PATH` as the two ways to pass it
- **AND** no container is started

#### Scenario: Same directory through a symlink in two modes

- **GIVEN** `~/repo-link` is a symlink to `~/repo`
- **WHEN** user runs `claude-docker ~/repo --ro=~/repo-link`
- **THEN** `run.sh` exits non-zero with a message naming both paths as the same directory
- **AND** no container is started

### Requirement: Read-only workspace mode

`run.sh` SHALL support a `--ro` flag that mounts every workspace argument read-only instead of read-write. Intended for code review / audit sessions where writes to the host must be prevented.

`run.sh` SHALL also accept a repeatable `--ro=PATH` flag that adds PATH as a workspace mounted read-only, leaving the mode of every other workspace unchanged. A `--ro=PATH` workspace SHALL keep its position among the workspace arguments and SHALL go through the same directory, basename and collision checks as a positional workspace. The first workspace SHALL be the working directory whether or not it was passed as `--ro=PATH`. A leading `~/` in PATH SHALL be expanded to `$HOME/`. An empty PATH (`--ro=`) SHALL be rejected with a non-zero exit before any container starts.

When a read-only workspace lies inside a writable workspace, `run.sh` SHALL print a warning to stderr naming both host paths, because the directory stays writable through the outer mount. The check SHALL compare paths with symlinks resolved. The session SHALL still start.

The `CLAUDE_DOCKER_FLAGS` statusline tag SHALL contain `ro` when every workspace is mounted read-only and `ro-partial` when only some are.

#### Scenario: --ro mounts workspaces read-only

- **WHEN** user runs `claude-docker --ro ~/repo`
- **THEN** `~/repo` is mounted at `/workspaces/repo` read-only
- **AND** writes to `/workspaces/repo/*` from inside the container fail with EROFS

#### Scenario: --ro=PATH mixes read-only and read-write workspaces

- **WHEN** user runs `claude-docker ~/repo --ro=~/reference`
- **THEN** `~/repo` is mounted read-write at `/workspaces/repo` and is the working directory
- **AND** `~/reference` is mounted read-only at `/workspaces/reference` and passed to `claude` as `--add-dir /workspaces/reference`
- **AND** the statusline tag contains `ro-partial`

#### Scenario: --ro=. mounts PWD read-only

- **WHEN** user runs `claude-docker --ro=. --ro=../shared` from `~/repo-a`
- **THEN** `~/repo-a` is mounted read-only at `/workspaces/repo-a` and is the working directory
- **AND** `~/shared` is mounted read-only at `/workspaces/shared`

#### Scenario: Read-only workspace nested in a writable one

- **WHEN** user runs `claude-docker ~/repo --ro=~/repo/vendor`
- **THEN** `run.sh` warns on stderr that `~/repo/vendor` stays writable under `/workspaces/repo`
- **AND** the container starts with `~/repo/vendor` mounted read-only at `/workspaces/vendor`

#### Scenario: Read-only symlink into a writable workspace

- **GIVEN** `~/vendor-link` is a symlink to `~/repo/vendor`
- **WHEN** user runs `claude-docker ~/repo --ro=~/vendor-link`
- **THEN** `run.sh` warns on stderr that `~/vendor-link` stays writable under `/workspaces/repo`

#### Scenario: Empty --ro= is rejected

- **WHEN** user runs `claude-docker --ro= ~/repo`
- **THEN** `run.sh` exits non-zero with an error naming `--ro=`
- **AND** no container is started
