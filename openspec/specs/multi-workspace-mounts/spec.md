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

### Requirement: Reject only basenames that break `docker -v` parsing

`run.sh` SHALL accept any workspace whose basename is non-empty and does not contain `:`. Specifically, basenames containing spaces, parentheses, `+`, `&`, `@`, `~`, `=`, or non-ASCII characters (e.g. `AI Policy`, `Project (v2)`, `2026年計画`) MUST mount successfully. `run.sh` SHALL reject only two cases with a non-zero exit and an error message naming the offending input:

1. Basenames containing `:`, because `docker -v src:dest[:opts]` uses `:` as a field separator and there is no way to escape it in short-form `-v` syntax.
2. Empty basenames, because `/workspaces/` is not a valid bind-mount target.

The error message MUST cite the actual disallowed input (`:` or empty), not a fictitious allowlist.

#### Scenario: Basename with spaces mounts successfully

- **GIVEN** a host directory at `/Users/me/AI Policy`
- **WHEN** the user runs `claude-docker "/Users/me/AI Policy"`
- **THEN** `run.sh` proceeds to `docker run` with `-v "/Users/me/AI Policy:/workspaces/AI Policy"` (a single quoted argv element)
- **AND** the container's working directory is set to `/workspaces/AI Policy`
- **AND** the agent can read and write files in that workspace

#### Scenario: Basename with parentheses and unicode mounts successfully

- **WHEN** the user runs `claude-docker "/Users/me/Project (v2)"`
- **THEN** the workspace is mounted at `/workspaces/Project (v2)` and the container starts normally

#### Scenario: Basename containing `:` is rejected

- **WHEN** the user runs `claude-docker "/Users/me/foo:bar"`
- **THEN** `run.sh` exits non-zero with an error message naming the input and identifying `:` as the disallowed character
- **AND** no container is started

#### Scenario: Empty basename is rejected

- **GIVEN** a workspace argument that resolves to an empty basename (e.g. `/`)
- **WHEN** the user runs `claude-docker /`
- **THEN** `run.sh` exits non-zero with an error message identifying the basename as empty
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

### Requirement: Nested worktrees portable via a container-only git config overlay

When a git worktree is nested inside its repository's directory tree (e.g. `<repo>/.claude/worktrees/<name>`), the same worktree directory mounted into the container at a different absolute path SHALL function for `git status`, `git log`, `git diff`, `git commit`, `git worktree add`, and `git worktree list` without requiring `git worktree repair`. This applies in both directions — host-created worktrees work in the container after a one-time `git worktree repair --relative-paths` (only for pre-existing absolute-path worktrees), and container-created worktrees work on the host with no extra step — because the relative offset between the worktree's `.git` link file and the repo's `.git/worktrees/<name>/` directory is preserved by any bind mount that includes the entire repo tree.

For every workspace whose `.git/config` is a regular file (i.e. the main repo, not a worktree pointer), `run.sh` SHALL inject a container-only `.git/config` overlay by copying the host's `.git/config` into the existing `$stage` directory, appending a `[core]` section bumping `repositoryformatversion` to 1 plus `[extensions] relativeWorktrees = true` and `[worktree] useRelativePaths = true`, and bind-mounting that file over `/workspaces/<name>/.git/config` in the container.

The host's on-disk `.git/config` SHALL NOT be modified by `run.sh` or by any operation performed inside the container. This is required to keep host tools that link against an older libgit2 (notably `gitstatusd`, which powers the Powerlevel10k git prompt) able to open the repo — those tools refuse to open a v1 repo declaring an unknown extension.

The overlay mount SHALL be writable (not `:ro`), so container-side operations that write to `.git/config` (e.g. `git remote add`, `git branch --set-upstream-to`) succeed. Such writes land in the ephemeral stage copy and are discarded at session end; persistent local-config edits are expected to happen on the host.

The overlay SHALL NOT be created for workspaces where `.git` is a pointer file rather than a directory (worktrees, submodules). Worktrees mounted alongside their main repo resolve through the main repo's overlay; worktrees mounted standalone (without their main repo) fall back to the existing `git worktree repair` workflow.

#### Scenario: Container-created nested worktree is portable to the host

- **GIVEN** the user runs `claude-docker <repo>` and `<repo>/.git/config` is a regular file
- **WHEN** they run `git worktree add .claude/worktrees/feature-y -b feature-y` inside the container
- **THEN** `<repo>/.git/worktrees/feature-y/gitdir` and `<repo>/.claude/worktrees/feature-y/.git` SHALL contain relative paths
- **AND** exiting the container and running `git status` in that worktree from the host SHALL succeed without `git worktree repair`

#### Scenario: Host's on-disk `.git/config` is not modified by container-side git operations

- **GIVEN** a repo whose host-visible `.git/config` does NOT contain `extensions.relativeWorktrees`
- **WHEN** the user runs `claude-docker <repo>` and performs any sequence of `git` operations inside (including `git worktree add`, `git remote add`, `git config --local`)
- **THEN** inspecting `<repo>/.git/config` from the host after the container exits SHALL show no new `extensions.relativeWorktrees`, no bumped `repositoryformatversion`, and no other writes performed by the container
- **AND** host tools that link against libgit2 versions predating January 2025 (e.g. `gitstatusd`) SHALL continue to open the repo without an "unknown extension" error

#### Scenario: Container-side `git` sees the relative-paths configuration

- **GIVEN** the user is inside `claude-docker` with the main repo mounted
- **WHEN** they run `git config --get extensions.relativeWorktrees` and `git config --get worktree.useRelativePaths`
- **THEN** both return `true`
- **AND** `git config --get core.repositoryformatversion` returns `1`

#### Scenario: Pre-existing absolute-path worktree fixed by one in-container repair

- **GIVEN** the user has a worktree at `<repo>/.claude/worktrees/old` created before this change (absolute paths in its link files)
- **WHEN** they run `claude-docker <repo>` and execute `git worktree repair --relative-paths .claude/worktrees/old` inside
- **THEN** the link files SHALL be rewritten with relative paths
- **AND** subsequent host-side and container-side git operations on that worktree SHALL succeed without further repair

