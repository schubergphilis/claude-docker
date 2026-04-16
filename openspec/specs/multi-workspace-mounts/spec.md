# multi-workspace-mounts

## Purpose

Let one container expose several host directories at stable container paths so cross-project work, sibling git worktrees, and cross-workspace session resume all function without extra configuration.

## Requirements

### Requirement: Variadic workspace args

`run.sh` SHALL accept N host directory paths as positional arguments and mount each at `/workspaces/<basename>` in the container. With no args, `$PWD` is mounted.

#### Scenario: Multiple dirs mounted

- **WHEN** user runs `~/claude-docker/run.sh ~/repo-a ~/repo-b`
- **THEN** `/workspaces/repo-a` and `/workspaces/repo-b` are both present and writable

#### Scenario: No args defaults to PWD

- **WHEN** user runs `~/claude-docker/run.sh` from `~/repo-a`
- **THEN** `~/repo-a` is mounted at `/workspaces/repo-a`

### Requirement: First arg is initial cwd

`claude` MUST launch with cwd set to the container path of the first workspace argument.

#### Scenario: First dir becomes cwd

- **WHEN** user runs `~/claude-docker/run.sh ~/repo-a ~/repo-b`
- **THEN** `claude` starts in `/workspaces/repo-a`

### Requirement: Sibling worktrees supported

Users SHALL be able to pass both a repo and its sibling git worktree (or a shared parent) so that git operations across them succeed.

#### Scenario: Sibling worktree accessible

- **GIVEN** `~/repo/main` and `~/repo/feature-x` are separate git worktrees
- **WHEN** user runs `~/claude-docker/run.sh ~/repo/main ~/repo/feature-x`
- **THEN** git operations in either dir resolve the other worktree successfully

### Requirement: Passthrough claude flags after `--`

`run.sh` SHALL treat a `--` token as a separator: positional args before it are workspaces, tokens after it are forwarded verbatim to the `claude` command inside the container.

#### Scenario: Resume mode via passthrough

- **WHEN** user runs `~/claude-docker/run.sh ~/repo-a -- --resume`
- **THEN** `~/repo-a` is mounted at `/workspaces/repo-a` and the container launches `claude --resume`

#### Scenario: No flags given

- **WHEN** user runs `~/claude-docker/run.sh ~/repo-a` (no `--`)
- **THEN** the container launches plain `claude` with no extra flags
