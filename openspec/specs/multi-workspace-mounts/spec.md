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

### Requirement: Reject basename collisions

When two or more workspace arguments resolve to the same basename, `run.sh` SHALL fail fast with a non-zero exit and an error identifying both host paths, rather than silently letting Docker drop all but the last mount.

#### Scenario: Colliding basenames error out

- **WHEN** user runs `claude-docker ~/client-a/api ~/client-b/api`
- **THEN** `run.sh` exits non-zero with a message naming both host paths
- **AND** no container is started

### Requirement: First arg is initial cwd

`claude` MUST launch with cwd set to the container path of the first workspace argument.

#### Scenario: First dir becomes cwd

- **WHEN** user runs `~/claude-docker/run.sh ~/repo-a ~/repo-b`
- **THEN** `claude` starts in `/workspaces/repo-a`

### Requirement: Sibling worktrees supported

Users SHALL be able to pass both a repo and its sibling git worktree (or a shared parent) so that git operations across them succeed. Because git worktrees embed absolute host paths in their `.git` files, users MAY need to run `git worktree repair` once inside the container to rewrite those paths.

#### Scenario: Sibling worktree accessible after repair

- **GIVEN** `~/repo/main` and `~/repo/feature-x` are separate git worktrees
- **WHEN** user runs `claude-docker ~/repo/main ~/repo/feature-x`
- **AND** runs `git worktree repair` inside the container
- **THEN** git operations in either dir resolve the other worktree successfully

### Requirement: Passthrough claude flags after `--`

`run.sh` SHALL treat a `--` token as a separator: positional args before it are workspaces (or recognised shortcut flags like `--yolo`), tokens after it are forwarded verbatim to the `claude` command inside the container.

#### Scenario: Resume mode via passthrough

- **WHEN** user runs `claude-docker ~/repo-a -- --resume`
- **THEN** `~/repo-a` is mounted at `/workspaces/repo-a` and the container launches `claude --resume`

#### Scenario: No flags given

- **WHEN** user runs `claude-docker ~/repo-a` (no `--`)
- **THEN** the container launches plain `claude` with no extra flags

### Requirement: Read-only workspace mode

`run.sh` SHALL support a `--ro` flag that mounts every workspace argument read-only instead of read-write. Intended for code review / audit sessions where writes to the host must be prevented.

#### Scenario: --ro mounts workspaces read-only

- **WHEN** user runs `claude-docker --ro ~/repo`
- **THEN** `~/repo` is mounted at `/workspaces/repo` read-only
- **AND** writes to `/workspaces/repo/*` from inside the container fail with EROFS

### Requirement: `--yolo` flag shortcut

`run.sh` SHALL recognise `--yolo` as a positional token (before `--`) and translate it to `--dangerously-skip-permissions` on the `claude` invocation.

#### Scenario: Yolo shortcut

- **WHEN** user runs `claude-docker --yolo ~/repo`
- **THEN** the container launches `claude --dangerously-skip-permissions` with `~/repo` mounted

#### Scenario: Yolo combines with passthrough

- **WHEN** user runs `claude-docker --yolo ~/repo -- --resume`
- **THEN** the container launches `claude --dangerously-skip-permissions --resume`
