## MODIFIED Requirements

### Requirement: Nested worktrees portable via a container-only git config overlay

When a git worktree is nested inside its repository's directory tree (e.g. `<repo>/.claude/worktrees/<name>`), the same worktree directory mounted into the container at a different absolute path SHALL function for `git status`, `git log`, `git diff`, `git commit`, `git worktree add`, and `git worktree list` without requiring `git worktree repair`. This applies in both directions — host-created worktrees work in the container after a one-time `git worktree repair --relative-paths` (only for pre-existing absolute-path worktrees), and container-created worktrees work on the host with no extra step — because the relative offset between the worktree's `.git` link file and the repo's `.git/worktrees/<name>/` directory is preserved by any bind mount that includes the entire repo tree.

For every workspace whose `.git/config` is a regular file (i.e. the main repo, not a worktree pointer), `run.sh` SHALL inject a container-only `.git/config` overlay by copying the host's `.git/config` into the existing `$stage` directory, appending a `[core]` section bumping `repositoryformatversion` to 1 plus `[extensions] relativeWorktrees = true` and `[worktree] useRelativePaths = true`, and bind-mounting that file over `/workspaces/<name>/.git/config` in the container.

The host's on-disk `.git/config` SHALL NOT be modified by `run.sh` or by any operation performed inside the container. This is required to keep host tools that link against an older libgit2 (notably `gitstatusd`, which powers the Powerlevel10k git prompt) able to open the repo — those tools refuse to open a v1 repo declaring an unknown extension.

The overlay mount SHALL be writable (not `:ro`), so container-side operations that write to `.git/config` (e.g. `git remote add`, `git branch --set-upstream-to`) succeed. Such writes land in the ephemeral stage copy and are discarded at session end; persistent local-config edits are expected to happen on the host.

The overlay SHALL NOT be created for workspaces where `.git` is a pointer file rather than a directory (worktrees, submodules). Worktrees mounted alongside their main repo resolve through the main repo's overlay; worktrees mounted standalone (without their main repo) fall back to the existing `git worktree repair` workflow.

The overlay SHALL NOT be created when `<ws>/.git` or `<ws>/.git/config` is a symbolic link, and `run.sh` SHALL NOT follow such a link when deciding whether to overlay or when copying — including a link swapped in while `run.sh` reads the file. `run.sh` SHALL enter `.git` and check it is the inode `lstat` named, then open `config` and check it is the inode `lstat` names, and copy only from that open file. The workspace is writable from inside the container, so a link planted there in one session, or swapped in by a running session while another launches, would otherwise make the launch copy an arbitrary host file — one outside every passed workspace — into the container. The same read SHALL be used for the `--glab` origin-host lookup.

On Windows hosts, the host's `core.autocrlf` value SHALL be carried into the overlay only when it is `true`, `false` or `input`.

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

#### Scenario: Symlinked .git or .git/config is not overlaid

- **GIVEN** a workspace whose `.git` is a symbolic link to a directory, or whose `.git/config` is a symbolic link to a file
- **WHEN** the user runs `claude-docker <workspace>`
- **THEN** no bind mount SHALL be created at `/workspaces/<name>/.git/config`
- **AND** the link target's contents SHALL NOT be copied into the stage directory

#### Scenario: A link swapped in during launch is not followed

- **GIVEN** a process keeps replacing `<ws>/.git/config`, or `<ws>/.git`, with a symbolic link to another host file or directory and back, while `run.sh` starts
- **WHEN** `run.sh` copies the overlay
- **THEN** the stage copy holds the workspace's own `.git/config`, or no overlay is created
- **AND** the other file's contents never reach the stage directory

## ADDED Requirements

### Requirement: Workspaces mount their physical path

`run.sh` SHALL resolve each workspace to its physical path (`cd -P` / `pwd -P`) and mount that path at `/workspaces/<basename of the physical path>`, since the engine follows symlinks in a mount source anyway. When the workspace argument itself is a symbolic link, `run.sh` SHALL print a one-line notice to stderr naming the directory it mounts, because a session whose workspace holds that link could have repointed it.

#### Scenario: A symlinked workspace is mounted as its target and announced

- **GIVEN** `~/link-ws` is a symbolic link to `~/real-target`
- **WHEN** the user runs `claude-docker ~/link-ws`
- **THEN** `~/real-target` is mounted at `/workspaces/real-target`
- **AND** stderr names `~/real-target` as the mounted directory
