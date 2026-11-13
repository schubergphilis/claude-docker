# multi-workspace-mounts

## Purpose

Let one container expose several host directories at stable container paths so cross-project work, sibling git worktrees, and cross-workspace session resume all function without extra configuration.

## Requirements

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

The overlay SHALL NOT be created for workspaces where `.git` is a pointer file rather than a directory (worktrees, submodules). Worktrees mounted alongside their main repo resolve through the main repo's overlay; worktrees mounted standalone (without their main repo) are covered by *A worktree's repository can be mounted read-only*, and otherwise fall back to the existing `git worktree repair` workflow.

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

### Requirement: Workspaces mount their physical path

`run.sh` SHALL resolve each workspace to its physical path (`cd -P` / `pwd -P`) and mount that path at `/workspaces/<basename of the physical path>`, since the engine follows symlinks in a mount source anyway. When the workspace argument itself is a symbolic link, `run.sh` SHALL print a one-line notice to stderr naming the directory it mounts, because a session whose workspace holds that link could have repointed it.

#### Scenario: A symlinked workspace is mounted as its target and announced

- **GIVEN** `~/link-ws` is a symbolic link to `~/real-target`
- **WHEN** the user runs `claude-docker ~/link-ws`
- **THEN** `~/real-target` is mounted at `/workspaces/real-target`
- **AND** stderr names `~/real-target` as the mounted directory

#### Scenario: One directory through a symlink in the same mode is refused

- **GIVEN** `~/repo-link` is a symbolic link to `~/repo`
- **WHEN** the user runs `claude-docker ~/repo ~/repo-link`
- **THEN** `run.sh` exits non-zero with a message naming both paths as the same directory, since both would be the same physical mount
- **AND** no container is started

### Requirement: Host path map on request

With `--host-paths`, or `CLAUDE_DOCKER_HOST_PATHS=1`, `run.sh` SHALL pass `claude` one `--append-system-prompt` listing each workspace's container path, its absolute host path with symlinks unresolved (Windows form under Git Bash), and whether it is read-only. The text SHALL tell the agent to work only through the container paths and to give the host path when it names a file for the user. Otherwise `run.sh` SHALL add no such text.

#### Scenario: Off by default

- **WHEN** user runs `claude-docker ~/repo`
- **THEN** the `claude` command carries no `--append-system-prompt` added by `run.sh`

#### Scenario: Map lists each workspace

- **WHEN** user runs `claude-docker --host-paths ~/repo --ro=~/lib`
- **THEN** the `claude` command carries one `--append-system-prompt` naming `/workspaces/repo` with `~/repo`'s path and `/workspaces/lib` with `~/lib`'s path marked read-only

### Requirement: Host path map leaves out control characters

A workspace whose host path or container path contains a control character SHALL be left out of the map, with a one-line warning on stderr naming its container path, control characters escaped. When every workspace is left out, `run.sh` SHALL add no text.

#### Scenario: Newline in a host path

- **GIVEN** a workspace whose host path contains a newline
- **WHEN** user runs `claude-docker --host-paths` with it
- **THEN** its host path is not in the map and a warning names its container path

#### Scenario: Newline in a container path reached through a symlink

- **GIVEN** a symlink with a plain name to a directory whose name contains a newline
- **WHEN** user runs `claude-docker --host-paths` with the symlink
- **THEN** the workspace is not in the map, the prompt gains no line from the directory name, and the warning is a single line

### Requirement: Host path map keeps the user's append

`claude` uses only the last `--append-system-prompt` it is given. Under `--host-paths`, `run.sh` SHALL remove every `--append-system-prompt VALUE` and `--append-system-prompt=VALUE` from the flags after `--` and append the last value, after a blank line, to the map in the same flag. A trailing `--append-system-prompt` with no value, and every `--append-system-prompt-file`, SHALL pass through unchanged.

#### Scenario: Both spellings, repeated

- **WHEN** user runs `claude-docker --host-paths ~/repo -- --append-system-prompt "A" --append-system-prompt=B`
- **THEN** the `claude` command carries exactly one `--append-system-prompt`, whose value is the map followed by `B`

#### Scenario: File form untouched

- **WHEN** user runs `claude-docker --host-paths ~/repo -- --append-system-prompt-file p.md`
- **THEN** `--append-system-prompt-file p.md` reaches `claude` unchanged, next to the map

### Requirement: A worktree's repository can be mounted read-only

When a workspace's `.git` is a regular file naming its gitdir by an absolute path, that gitdir has a `commondir`, and the git directory it leads to lies inside no mounted workspace, `run.sh` SHALL offer to mount that git directory read-only at the path the `.git` file and `commondir` name (normalized, symlinks unresolved), so the pointer resolves unchanged. Accepted, it SHALL print a notice naming it. Worktrees of one repository SHALL lead to one offer.

#### Scenario: Accepting the offer makes git read work in the worktree

- **GIVEN** `~/wt` is a worktree of `~/repo` whose `.git` file names `/Users/me/repo/.git/worktrees/wt`
- **WHEN** the user runs `claude-docker ~/wt` on a terminal and presses Enter at the question
- **THEN** the git directory is mounted read-only at `/Users/me/repo/.git` in the container, and a notice names it
- **AND** `git status`, `git log` and `git diff` in `/workspaces/wt` succeed
- **AND** `git commit` there fails without changing anything on the host

#### Scenario: The repository is already a workspace

- **WHEN** the user runs `claude-docker ~/repo ~/wt`
- **THEN** no question is asked and nothing extra is mounted

#### Scenario: Two worktrees of one repository

- **WHEN** the user runs `claude-docker ~/wt-a ~/wt-b` and both are worktrees of `~/repo`
- **THEN** one question is asked, the repository's shared parts are mounted once, and each worktree's own entry is mounted

### Requirement: Only what git reads is mounted from a worktree's repository

For an accepted offer `run.sh` SHALL mount read-only, each from its physical host path: `HEAD`, `objects` and `refs`, and `packed-refs`, `reftable` and `shallow` when present, and the `worktrees/<name>` entry of each worktree passed. Nothing else of the git directory SHALL be mounted (not its hooks, reflogs, other worktrees' entries, `modules` or `lfs`), nor the repository's working tree.

#### Scenario: Hooks, other worktrees and the working tree stay on the host

- **GIVEN** `~/repo/.git` has `hooks/`, `logs/` and a second worktree's entry `worktrees/other`
- **WHEN** the user accepts the offer for `~/wt`
- **THEN** none of those, nor the files of `~/repo` outside `.git`, are in the container

### Requirement: A worktree's repository config is mounted as a format-only copy

In place of the repository's `config`, `run.sh` SHALL mount a copy holding only the `core.repositoryformatversion` and `extensions.*` entries that have no subsection and a plain-word value, read without following a symlink or an `include`. A `config.worktree` in the worktree's entry SHALL be replaced the same way, keeping only `core.sparseCheckout` and `core.sparseCheckoutCone`.

#### Scenario: The repository's config does not reach the container

- **GIVEN** `~/repo/.git/config` sets `remote.origin.url` with a token in it, `core.hooksPath`, `core.fsmonitor` and `extensions.objectFormat = sha256`
- **WHEN** the user accepts the offer
- **THEN** `/Users/me/repo/.git/config` in the container holds `core.repositoryformatversion` and `extensions.objectformat` only

#### Scenario: A symlinked config mounts nothing

- **GIVEN** `~/repo/.git/config` is a symbolic link
- **WHEN** the user accepts the offer
- **THEN** nothing is mounted for `~/wt`, and a warning says so

### Requirement: The worktree mount is checked again before the container starts

Just before starting the container, after the question, `run.sh` SHALL check that each worktree's pointer still leads to the same git directory, that it still has the same physical path and dev:inode as when offered, and that nothing mounted from it is a symbolic link. Otherwise it SHALL mount nothing for that worktree and print a warning. A swap after that, as the runtime resolves the sources, is out of its reach.

#### Scenario: A repository swapped while the question waits is not mounted

- **GIVEN** the user has been asked about `~/repo/.git`
- **WHEN** another session replaces `~/repo/.git` with a symbolic link, or with another directory, before the user answers
- **THEN** nothing is mounted for `~/wt`, and a warning says so

### Requirement: Only a real worktree of a repository you own is offered

`run.sh` SHALL make the offer only when the gitdir is `<git directory>/worktrees/<name>` both as normalized text and as physical path, the git directory has `HEAD`, `objects` and `refs`, and the gitdir's own `gitdir` file names the workspace's `.git`. It SHALL make it only for a workspace it vouches for under *In-container git trusts only the workspaces you own*, and not on Windows hosts or without `git` on the host.

#### Scenario: Another user's repository is not offered

- **GIVEN** `~/wt` is a worktree whose gitdir, or that gitdir's commondir, another host user owns
- **WHEN** the user runs `claude-docker ~/wt`
- **THEN** no question is asked and nothing is mounted for it

#### Scenario: A planted pointer to a directory that is no worktree's repository is not offered

- **GIVEN** a session wrote `~/wt/.git` to name a gitdir whose `commondir` leads to the user's home directory, or to another repository's worktree gitdir, or through a symlink to a path other than the one git opens
- **WHEN** the user runs `CLAUDE_DOCKER_WORKTREE_GITDIR=ro claude-docker ~/wt`
- **THEN** no question is asked and nothing is mounted for it

### Requirement: The worktree mount avoids container paths and unsafe characters

`run.sh` SHALL NOT offer a mount at `/`, or at or under `/workspaces`, `/root`, `/proc`, `/sys`, `/dev`, `/etc`, `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/run` or `/boot`, nor when the git directory's path, as named or physical, or the worktree's name contains `:`, `,` or a control character.

#### Scenario: A path with a control character is not offered

- **GIVEN** `~/wt` is a worktree of a repository whose directory name holds an escape sequence, a `:` or a `,`
- **WHEN** the user runs `claude-docker ~/wt`
- **THEN** no question is asked and nothing is mounted for it

### Requirement: CLAUDE_DOCKER_WORKTREE_GITDIR decides the worktree mount offer

`CLAUDE_DOCKER_WORKTREE_GITDIR` SHALL decide the offer: `ask` (the default, also when unset or empty) asks on the terminal, `ro` mounts without asking, `off` never mounts. Any other value SHALL stop `claude-docker` before any container starts. Asked, an empty answer or `y`/`yes` in any case accepts, anything else declines. Without a terminal on stdin and stderr, `ask` declines without reading. A decline SHALL print a warning naming the workspace.

#### Scenario: Declining leaves git broken and says so

- **WHEN** the user answers `n`, or `CLAUDE_DOCKER_WORKTREE_GITDIR=off` is set
- **THEN** nothing is mounted for the repository
- **AND** a warning names `~/wt` and says git won't work there
- **AND** the session starts

#### Scenario: Pre-approved without a question

- **GIVEN** `CLAUDE_DOCKER_WORKTREE_GITDIR=ro`
- **WHEN** the user runs `claude-docker ~/wt`
- **THEN** no question is asked, and the git directory is mounted read-only with a notice

#### Scenario: No terminal, no mount

- **GIVEN** `CLAUDE_DOCKER_WORKTREE_GITDIR` is unset and stdin is not a terminal
- **WHEN** `claude-docker ~/wt` runs
- **THEN** nothing is read from stdin, nothing is mounted, and the warning is printed

#### Scenario: An unknown value is refused

- **WHEN** the user runs `CLAUDE_DOCKER_WORKTREE_GITDIR=rw claude-docker ~/wt`
- **THEN** `claude-docker` exits non-zero with an error naming `CLAUDE_DOCKER_WORKTREE_GITDIR`
- **AND** no container is started
