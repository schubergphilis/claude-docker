# Spec Delta

## MODIFIED Requirements

### Requirement: Variadic workspace args

`run.sh` SHALL accept N host directory paths as positional arguments and mount each at `/workspaces/<basename>` in the container, or under `--docker` at the workspace's own host path (capability `host-container-engine`). With no workspace args, `$PWD` is mounted. A `--ro=PATH` flag counts as a workspace arg, so `$PWD` is the default only when neither positional workspaces nor `--ro=PATH` flags are given.

#### Scenario: Multiple dirs mounted

- **WHEN** user runs `~/claude-docker/run.sh ~/repo-a ~/repo-b`
- **THEN** `/workspaces/repo-a` and `/workspaces/repo-b` are both present and writable

#### Scenario: No args defaults to PWD

- **WHEN** user runs `~/claude-docker/run.sh` from `~/repo-a`
- **THEN** `~/repo-a` is mounted at `/workspaces/repo-a`

#### Scenario: --ro=PATH replaces the PWD default

- **WHEN** user runs `claude-docker --ro=~/shared` from `~/repo-a`
- **THEN** only `~/shared` is mounted, read-only at `/workspaces/shared`, and it is the working directory

#### Scenario: --docker mounts at the host path

- **WHEN** user runs `claude-docker --docker ~/repo-a ~/repo-b`
- **THEN** `~/repo-a` and `~/repo-b` are mounted at their own host paths, the session starts in `~/repo-a`, and `~/repo-b` is passed to claude as `--add-dir`
