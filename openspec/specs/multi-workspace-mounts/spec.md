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

### Requirement: Additional workspaces granted to claude

For every workspace argument beyond the first, `run.sh` SHALL pass `--add-dir <container-path>` to the `claude` invocation so the agent has read/write scope over every mounted workspace, not just the cwd. The first workspace is omitted because cwd already grants it. The wrapper does not dedupe against any user-supplied `--add-dir` after `--`; `claude` accepts repeated occurrences.

#### Scenario: Extra workspaces become additional working dirs

- **WHEN** user runs `claude-docker ~/repo-a ~/repo-b ~/repo-c`
- **THEN** the container launches `claude --add-dir /workspaces/repo-b --add-dir /workspaces/repo-c`
- **AND** the agent can read and write files in all three workspaces

#### Scenario: Single workspace adds no flag

- **WHEN** user runs `claude-docker ~/repo`
- **THEN** the container launches `claude` with no `--add-dir` flag

#### Scenario: --ro workspaces still added

- **WHEN** user runs `claude-docker --ro ~/repo-a ~/repo-b`
- **THEN** the container launches `claude --add-dir /workspaces/repo-b`
- **AND** writes to either workspace fail with EROFS at the OS layer (the `--add-dir` flag itself has no read-only mode)

### Requirement: Nested worktrees portable via relative paths

When a git worktree is nested inside its repository's directory tree (e.g. `<repo>/.claude/worktrees/<name>`) AND the repo has been opted in to relative-path worktrees (`git config worktree.useRelativePaths true` plus `git worktree repair --relative-paths` for any pre-existing worktree), the same worktree directory mounted into the container at a different absolute path SHALL function for `git status`, `git log`, `git diff`, `git commit`, `git worktree add`, and `git worktree list` without requiring `git worktree repair`. This applies in both directions — host-created worktrees work in the container, and container-created worktrees work on the host — because the relative offset between the worktree's `.git` link file and the repo's `.git/worktrees/<name>/` directory is preserved by any bind mount that includes the entire repo tree.

The container image SHALL ship a `git` version (≥ 2.48) that supports both reading and writing relative-path worktrees, including the `extensions.relativeWorktrees` repository extension that git 2.48+ sets as a safety lock when relative paths are in use. Older git versions refuse to operate on a repo with this extension set, so the container's git MUST be at the supporting version for the workflow to function at all once the host has opted in.

This requirement assumes the user's host git is also ≥ 2.48 (needed to write the initial `--relative-paths` repair). Hosts on older git fall back to the existing repair-based workflow — see "Sibling worktrees supported".

#### Scenario: Host-created nested worktree round-trips between host and container without repair

- **GIVEN** the host has git ≥ 2.48 and ran `git config worktree.useRelativePaths true` in the repo
- **AND** a worktree exists at `<repo>/.claude/worktrees/feature-x` (created with relative paths, or migrated via `git worktree repair --relative-paths`)
- **WHEN** the user runs `claude-docker <repo>` on the host and the repo is mounted at `/workspaces/<repo-basename>` in the container
- **THEN** `git status` inside `/workspaces/<repo-basename>/.claude/worktrees/feature-x` succeeds without prompting for repair
- **AND** the user can exit the container and run `git status` in the same worktree on the host without any repair step

#### Scenario: Container-created worktree is portable to the host

- **GIVEN** the user is inside `claude-docker` with the repo configured for relative-path worktrees
- **WHEN** they run `git worktree add .claude/worktrees/feature-y -b feature-y`
- **THEN** the link files written under `<repo>/.git/worktrees/feature-y/` and `<repo>/.claude/worktrees/feature-y/.git` SHALL contain relative paths
- **AND** exiting the container and running `git status` in that worktree from the host succeeds without `git worktree repair`

#### Scenario: Container's git accepts the extensions.relativeWorktrees flag

- **GIVEN** a repo on which the host has run `git worktree repair --relative-paths` (which sets `extensions.relativeWorktrees = true` in `.git/config`)
- **WHEN** the user runs `claude-docker <repo>` and runs any git command inside the mounted repo
- **THEN** the command succeeds (i.e. the container's git does NOT abort with `fatal: unknown repository extension found: relativeworktrees`)

### Requirement: Sibling worktrees supported

Users SHALL be able to pass both a repo and its sibling git worktree (or a shared parent) as separate workspace arguments so that git operations across them succeed. Because each workspace argument is bind-mounted at `/workspaces/<basename>` in the container, the relative offset between the worktree's `.git` link file and the repo's `.git/worktrees/<name>/` directory is NOT preserved (the host parent directory does not appear in the container). For this layout, users MAY need to run `git worktree repair` once inside the container to rewrite the link-file paths, regardless of whether `worktree.useRelativePaths` is set on the host.

This requirement covers only sibling-flattened layouts, and also covers hosts whose git version is < 2.48 (where opt-in to relative paths is unavailable, so the absolute-path repair flow is the only option). Worktrees nested inside the repository tree on hosts with git ≥ 2.48 are covered by the "Nested worktrees portable via relative paths" requirement.

#### Scenario: Sibling worktree accessible after repair

- **GIVEN** `~/repo/main` and `~/repo/feature-x` are separate git worktrees passed as separate workspace arguments
- **WHEN** user runs `claude-docker ~/repo/main ~/repo/feature-x`
- **AND** runs `git worktree repair` inside the container
- **THEN** git operations in either dir resolve the other worktree successfully

#### Scenario: Repair is still required even with relative paths configured

- **GIVEN** the host has `git config worktree.useRelativePaths true` set in the repo
- **AND** `~/repo` and `~/repo-feature` are passed as separate workspace arguments
- **WHEN** user runs `claude-docker ~/repo ~/repo-feature`
- **THEN** `git status` inside `/workspaces/repo-feature` MAY fail until `git worktree repair` is run, because the relative offset between the two workspaces differs between host and container

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
