## Why

A workspace that is a git worktree has a `.git` file naming its gitdir by its
host path, inside the main repository's `.git`. `claude-docker` mounts only the
workspaces it is given, so when the main repository isn't one of them that
path doesn't exist in the container. Git fails in the worktree with
`fatal: not a git repository`, and since v1.3.2 the entrypoint's trust step
failed the same way and stopped the session from starting.

The entrypoint fix in this change lets the session start, but git in the
worktree still fails, silently from the user's point of view: nothing at
startup says why. Users of tools that keep worktrees outside the repository
(Superset, `git worktree add ../x`) hit this every time.

## What Changes

- **The entrypoint runs its `git config --file` calls from `/`**, so a
  workspace with a dangling `.git` pointer no longer aborts startup. What it
  writes to `/etc/gitconfig` is unchanged.
- **`run.sh` offers to mount the worktree's repository read-only.** For each
  workspace whose `.git` file names a gitdir by absolute path, in a repository
  whose git directory isn't inside a mounted workspace, `run.sh` asks:
  ```
  claude-docker: '~/wt' is a git worktree of a repository that isn't mounted, so git won't work in it.
  claude-docker: mount its git directory '/Users/me/repo/.git' read-only? Git can then show status, history and diffs, but not commit. [Y/n]
  ```
  - Yes (the default): the repository's git directory, and only that, is
    mounted read-only at the path the `.git` file names, so the pointer
    resolves unchanged. A notice says so.
  - No: nothing is mounted, and a warning says git won't work there.
  - One question per repository, however many of its worktrees are passed.
- **`CLAUDE_DOCKER_WORKTREE_GITDIR`** answers in advance: `ro` mounts without
  asking, `off` never mounts, `ask` (the default) asks. Any other value stops
  `claude-docker` before a container starts.
- **No terminal, no mount.** When stdin or stderr isn't a terminal and the
  variable isn't `ro`, nothing is mounted and the warning is printed, so a
  scripted session never gets access nobody approved.
- **Only for workspaces `run.sh` vouches for** (`build_git_trust`): git would
  refuse another user's repository anyway, and its config and hooks have no
  business in the session.

## Non-goals

- Making git writable in such a worktree. Committing needs the repository's
  objects, refs and the worktree's index to be writable; passing the main
  repository as a workspace (with `git worktree repair`) stays the route for
  that.
- Worktrees whose `.git` file names a relative path, and submodules. A
  relative path resolves against `/workspaces/<name>` in the container, not
  against the host directory; a submodule's gitdir carries a `core.worktree`
  pointing at its host location. Both keep today's behaviour.
- Windows hosts. The host path (`C:/...`) is no path in the container.

## Capabilities

### Modified Capabilities

- `multi-workspace-mounts`:
  - ADDED *A worktree's repository can be mounted read-only*.
  - MODIFIED *Nested worktrees portable via a container-only git config
    overlay*: a worktree mounted without its main repository no longer only
    falls back to `git worktree repair`; it gets the offer above.

`container-runtime` is unchanged: *The entrypoint writes the vouched-for
workspaces to system git config* holds as written, and git matches
`safe.directory` against the worktree path, which is already trusted.

## Impact

- `entrypoint.sh`: `trust_workspaces` runs git from `/`.
- `run.sh`: `build_git_trust` keeps which workspaces it vouched for;
  new `build_worktree_gitdirs` after it; `validate_opts` checks
  `CLAUDE_DOCKER_WORKTREE_GITDIR`.
- `tests/bats/entrypoint.bats`, `tests/bats/run.bats`.
- `docs/usage.md` (Git worktrees), `docs/security.md` (what is mounted).
