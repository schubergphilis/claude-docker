# Read-only mounts for individual workspaces

## Why

`--ro` mounts every workspace read-only, so a session cannot mix a writable repo with read-only reference directories (a shared module library, a second repo to compare against). Today the only choices are to make all of them writable or none.

## What Changes

- New repeatable wrapper flag `--ro=PATH`: mounts PATH as a workspace, read-only. Other workspaces keep their mode. Plain `--ro` is unchanged and still makes every workspace read-only.
- A `--ro=PATH` workspace is an ordinary workspace argument in every other respect: it keeps its place in the order (the first workspace is the working directory), goes through the same directory, basename and collision checks, and is passed to `claude` as `--add-dir`. It also counts towards the `$PWD` default, which applies only when no workspace is given at all: `claude-docker . --ro=../lib`, not `claude-docker --ro=../lib`. Forgetting the `.` fails safe (only `lib`, read-only).
- A leading `~/` in PATH is expanded, because shells do not tilde-expand after `--ro=`. `--ro=` with an empty PATH is rejected.
- Overlaps between read-only and writable workspaces, compared with symlinks resolved:
  - the same path twice (`~/repo --ro=~/repo`) gets a "given more than once" error instead of a basename collision naming the path twice;
  - the same directory through a symlink, once read-write and once read-only, is refused, since the read-only mount would protect nothing (same-mode symlink duplicates keep mounting, as on main);
  - a read-only workspace inside a writable one (`~/repo --ro=~/repo/vendor`) gets a warning, not an error, since a read-only view of a subtree can be deliberate.
- `--ro=PATH` is not an isolation boundary for untrusted content: what the agent reads there can drive writes to the writable workspaces (git hooks, `.envrc`). The help and security docs say so and keep `--ro` (every workspace) as the advice for untrusted repos.
- Statusline tag: `ro` when every workspace is read-only, `ro-partial` when only some are.
- Non-goal: a Docker-style `PATH:ro` suffix. Paths may contain `:` (Windows drive letters via `claude-docker.ps1`), so the suffix would be ambiguous.

## Capabilities

- `multi-workspace-mounts`: MODIFIED (variadic workspace args, basename collisions, read-only workspace mode).
- `cli-help`: MODIFIED (help lists `--ro=PATH`).

## Impact

`run.sh`, `tests/bats/run.bats`, `docs/usage.md`, `docs/security.md`, `SECURITY.md`.
