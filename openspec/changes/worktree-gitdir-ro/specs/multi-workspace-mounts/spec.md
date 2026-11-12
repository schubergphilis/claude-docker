## ADDED Requirements

### Requirement: A worktree's repository can be mounted read-only

When a workspace's `.git` is a regular file naming its gitdir by an absolute path, that gitdir has a `commondir`, and the repository's git directory it leads to lies inside no mounted workspace, `run.sh` SHALL offer to mount what git reads from that git directory, read-only. Accepted, `run.sh` SHALL bind-mount, each read-only from its physical host path at its place under the path the `.git` file and `commondir` name (normalized, symlinks unresolved), so the pointer resolves unchanged in the container: `HEAD`, `objects`, `refs`, `packed-refs`, `reftable` and `shallow` (the last three when present), and the `worktrees/<name>` entry of each such workspace passed. It SHALL mount, as `config`, a copy of the repository's config holding only `core.repositoryformatversion` and `extensions.*` entries without a subsection whose value is a plain word, read without following a symlink or an `include`; and, when the entry has a `config.worktree`, a copy of it holding only `core.sparseCheckout` and `core.sparseCheckoutCone`. Nothing else of the git directory SHALL be mounted (not its hooks, reflogs, other worktrees' entries, `modules` or `lfs`), nor the repository's working tree. `run.sh` SHALL print a notice naming the git directory.

Because the repository may sit in a directory another session can write, `run.sh` SHALL check again just before starting the container, after the question: each workspace's pointer SHALL still lead to the same git directory, that directory SHALL still have the same physical path and dev:inode as when it was offered, and none of the paths mounted from it SHALL be a symbolic link. Otherwise nothing SHALL be mounted for that workspace and `run.sh` SHALL print a warning. The runtime resolves each source once more as it starts the container; a swap in that moment is out of reach of `run.sh`.

Because the workspace is writable from the container, `run.sh` SHALL make the offer only when what the `.git` file leads to is laid out as git lays out a worktree: the gitdir SHALL be `<git directory>/worktrees/<name>` both as normalized text and as physical path (no symlink or `..` between them), the git directory SHALL have `HEAD`, `objects` and `refs`, and the gitdir's own `gitdir` file SHALL name the workspace's `.git` (absolute, or relative to the gitdir). Otherwise no offer and no mount SHALL follow.

`run.sh` SHALL make the offer only for a workspace it vouches for under *In-container git trusts only the workspaces you own*, SHALL NOT make it on Windows hosts or without `git` on the host, and SHALL NOT mount at `/`, or at or under `/workspaces`, `/root`, `/proc`, `/sys`, `/dev`, `/etc`, `/usr`, `/bin`, `/sbin`, `/lib`, `/lib64`, `/run` or `/boot`, or when the git directory's path as named or physical, or the worktree's name, contains `:`, `,` or a control character. Several workspaces that are worktrees of one repository SHALL lead to one offer, and the repository's shared parts SHALL be mounted once.

`CLAUDE_DOCKER_WORKTREE_GITDIR` SHALL decide the offer: `ask` (the default, also when unset or empty) asks on the terminal, `ro` mounts without asking, `off` never mounts. Any other value SHALL stop `claude-docker` with an error naming the variable before any container starts. Asked, an empty answer or `y`/`yes` in any case SHALL accept; anything else SHALL decline. When stdin or stderr is not a terminal, `ask` SHALL decline without reading.

Whenever the offer is declined, `run.sh` SHALL print a warning naming the workspace and the repository's git directory, saying git won't work there. The session SHALL start either way.

#### Scenario: Accepting the offer makes git read work in the worktree

- **GIVEN** `~/wt` is a worktree of `~/repo` whose `.git` file names `/Users/me/repo/.git/worktrees/wt`
- **WHEN** the user runs `claude-docker ~/wt` on a terminal and presses Enter at the question
- **THEN** `HEAD`, `objects`, `refs` and `worktrees/wt` of `/Users/me/repo/.git` are mounted read-only at the same paths in the container, with the config copy at `/Users/me/repo/.git/config`, and a notice names it
- **AND** `git status`, `git log` and `git diff` in `/workspaces/wt` succeed
- **AND** `git commit` there fails without changing anything on the host
- **AND** the files of `~/repo` outside `.git`, its hooks, and its other worktrees' entries are not in the container

#### Scenario: The repository's config does not reach the container

- **GIVEN** `~/repo/.git/config` sets `remote.origin.url` with a token in it, `core.hooksPath`, `core.fsmonitor` and `extensions.objectFormat = sha256`
- **WHEN** the user accepts the offer
- **THEN** `/Users/me/repo/.git/config` in the container holds `core.repositoryformatversion` and `extensions.objectformat` only

#### Scenario: A repository swapped while the question waits is not mounted

- **GIVEN** the user has been asked about `~/repo/.git`
- **WHEN** another session replaces `~/repo/.git` with a symbolic link, or with another directory, before the user answers
- **THEN** nothing is mounted for `~/wt`, and a warning says so

#### Scenario: Declining leaves git broken and says so

- **WHEN** the user answers `n`, or `CLAUDE_DOCKER_WORKTREE_GITDIR=off` is set
- **THEN** nothing is mounted for the repository
- **AND** a warning names `~/wt` and `/Users/me/repo/.git` and says git won't work there
- **AND** the session starts

#### Scenario: Pre-approved without a question

- **GIVEN** `CLAUDE_DOCKER_WORKTREE_GITDIR=ro`
- **WHEN** the user runs `claude-docker ~/wt`
- **THEN** no question is asked, and what git needs from the git directory is mounted read-only with a notice

#### Scenario: No terminal, no mount

- **GIVEN** `CLAUDE_DOCKER_WORKTREE_GITDIR` is unset and stdin is not a terminal
- **WHEN** `claude-docker ~/wt` runs
- **THEN** nothing is read from stdin, nothing is mounted, and the warning is printed

#### Scenario: The repository is already a workspace

- **WHEN** the user runs `claude-docker ~/repo ~/wt`
- **THEN** no question is asked and nothing extra is mounted

#### Scenario: Two worktrees of one repository

- **WHEN** the user runs `claude-docker ~/wt-a ~/wt-b` and both are worktrees of `~/repo`
- **THEN** one question is asked, `objects` and the other shared parts are mounted once, and each worktree's own entry is mounted

#### Scenario: Another user's repository is not offered

- **GIVEN** `~/wt` is a worktree whose gitdir, or that gitdir's commondir, another host user owns
- **WHEN** the user runs `claude-docker ~/wt`
- **THEN** no question is asked and nothing is mounted for it

#### Scenario: A planted pointer to a directory that is no worktree's repository is not offered

- **GIVEN** a session wrote `~/wt/.git` to name a gitdir whose `commondir` leads to the user's home directory, or to another repository's worktree gitdir, or through a symlink to a path other than the one git opens
- **WHEN** the user runs `CLAUDE_DOCKER_WORKTREE_GITDIR=ro claude-docker ~/wt`
- **THEN** no question is asked and nothing is mounted for it

#### Scenario: An unknown value is refused

- **WHEN** the user runs `CLAUDE_DOCKER_WORKTREE_GITDIR=rw claude-docker ~/wt`
- **THEN** `claude-docker` exits non-zero with an error naming `CLAUDE_DOCKER_WORKTREE_GITDIR`
- **AND** no container is started

## MODIFIED Requirements

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
