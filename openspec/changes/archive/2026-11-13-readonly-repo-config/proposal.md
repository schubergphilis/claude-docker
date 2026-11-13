## Why

Each workspace's `.git/config` is a single-file bind mount of a container-only
copy (the relative-worktrees overlay). git saves config by renaming
`config.lock` over the file, and a rename over a mountpoint fails, so routine
steps print `could not write config file .git/config: Device or resource busy`:
`git push -u`, creating a branch from a remote one, `git branch -d`,
`git worktree add -b`. The spec and docs said these writes succeed and are
dropped at exit. The agent then spends turns debugging its environment, and
`git push -u` reports success without recording the upstream (#1).

The team agreed on six guarantees in #1. This change delivers the first:
repo config is read-only in a session, and the session knows it. #224
delivered the launch hardening (#211); the threat model follows separately.

## What Changes

- The overlay is mounted `:ro`. git's own writes already fail; this also fails a
  tool that writes the file in place, which would otherwise succeed and vanish
  at exit. Every write fails the same way.
- When any overlay is mounted, `run.sh` prints one line at start, and appends a
  note for `claude` (in the same `--append-system-prompt` as the `--host-paths`
  map, before the user's own text) that quotes git's message, says it needs
  no fixing, and says to push with `git push origin HEAD`.
- The image sets `branch.autoSetupMerge = false` in `/etc/gitconfig`, so
  creating a branch doesn't try to save tracking. System scope rather than
  `GIT_CONFIG_*` env, which a session export would replace; repo and global
  config still override it.
- Docs: `docs/usage.md` replaces the "writes land in the ephemeral overlay"
  trade-off with what fails and what to do instead; `docs/auth.md` points there.

## Capabilities

### Modified Capabilities

- `multi-workspace-mounts`: the overlay is read-only and the session is told;
  `run.sh`'s appended text can carry that note as well as the host path map.

## Impact

- `run.sh` (`stage_git_overlays`, `add_claude_flags`), `Dockerfile`,
  `tests/bats/run.bats`, `tests/test_windows_host.py` (its docker stub matches
  the `:ro` mount), `tests/smoke/` (the smoke workspace is now a repo, so
  every Docker cell checks the mount, the system setting, git's message and an
  in-place write, and that the host file is unchanged), `docs/usage.md`,
  `docs/auth.md`.
- Anyone relying on in-session `git remote add` or `git config --local`: those
  already failed with `EBUSY`; nothing that worked before stops working, except
  a non-git tool writing `.git/config` in place.
