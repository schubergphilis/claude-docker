## Why

Repos that use Git LFS carry `[filter "lfs"]` definitions (`clean` / `smudge` /
`process`, with `required = true`) in their git config. `run.sh` copies the host
repo's `.git/config` verbatim into the container's config overlay, so those
filter entries reach the container — but the image ships `git` without
`git-lfs`. The moment git runs a checkout that invokes the filter — and
`git worktree add` checks out HEAD into the new worktree — it fails with
`git: 'lfs' is not a git command` / `error: external filter 'git-lfs
filter-process' failed`. Because `filter.lfs.required = true` is LFS's default,
this is a hard error, not a warning: creating a worktree (or any checkout)
inside the container aborts, and the session fails to start.

## What Changes

- **Install `git-lfs`** in the image alongside `git`, from Ubuntu's main archive
  (unpinned, consistent with `git` / `tmux`; `.hadolint.yaml` already waives
  DL3008 with a documented rationale).
- **Register the LFS filters system-wide** at build time with
  `git lfs install --system --skip-repo` so LFS works regardless of whether the
  host kept its filter config repo-local (copied into the container by the
  existing overlay) or only in the host global `~/.gitconfig` (which the
  container does NOT inherit — only `user.name` / `user.email` are forwarded).
- **Update README** to list `git-lfs` among the bundled tools.

Out of scope: no new `run.sh` flag, no credential handling, no runtime
code-fetch surface (the LFS binary is baked at build time; `git lfs pull` uses
the same remotes git already reaches). No host-side change.

## Capabilities

### New Capabilities

None. This extends an existing capability.

### Modified Capabilities

- `external-cli-tools`: adds a requirement that the image ship `git-lfs` on the
  default PATH with the LFS filters registered system-wide, so checkouts on
  LFS-backed repos — including the worktree checkout that `git worktree add`
  performs — succeed instead of aborting on the missing filter program.

## Impact

- **Code**: `claude-docker/Dockerfile` — add `git-lfs` to the apt install list
  and add a `git lfs install --system --skip-repo` step.
- **Docs**: `claude-docker/README.md` — mention `git-lfs` in the bundled-tools
  line.
- **Specs**: delta to `external-cli-tools`.
- **No breaking changes**: purely additive; non-LFS repos are unaffected.
- **Dependencies**: adds the `git-lfs` package (Ubuntu archive). No new runtime
  network egress beyond the git remotes the repo already uses.
