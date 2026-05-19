## Why

The previous `worktree-relative-paths` change told users to opt in on the host: `git config worktree.useRelativePaths true`, then `git worktree repair --relative-paths`. Setting that combination writes `extensions.relativeWorktrees = true` into the repo's `.git/config` (with `core.repositoryformatversion = 1`). Tools that link against an older libgit2 — notably `gitstatusd`, which powers Powerlevel10k's git prompt — refuse to open a v1 repo declaring an extension they don't understand. Upstream `gitstatusd` still bundles libgit2 v1.5.4 (Feb 2022), predating the extension (added Jan 2025), and a bump-tracking issue has been open with no movement. Result: the user's prompt went silent on every repo where the opt-in had been applied, with no obvious indication it was the config flag rather than a broken repo.

We only need the *container side* to write relative-path link files. The host doesn't need the extension flag on its side — it just needs to be able to *read* relative-path link files, which old libgit2 does fine (the format-version lock is on opening repos that declare the extension, not on resolving relative gitdir contents). So the host/container asymmetry — previously rejected as a leaky abstraction — is exactly the property we want.

## What Changes

- **`run.sh`**: for every workspace whose `.git/config` is a regular file (i.e. the main repo, not a worktree/submodule pointer), copy that file into the existing `$stage` dir, append a `[core]` section bumping `repositoryformatversion` to 1, plus `[extensions] relativeWorktrees = true` and `[worktree] useRelativePaths = true`, and bind-mount the augmented copy over `/workspaces/<name>/.git/config`. Overlay is writable so container-side `git config`/`git remote add` don't error; those writes land in the ephemeral stage copy and are discarded at exit (`run.sh`'s existing `trap` already handles cleanup).
- **README "Git worktrees" section**: retract the host-side opt-in. Document that claude-docker now overlays the necessary git config inside the container automatically — no host config change needed. Document the ephemeral-config-writes trade-off and the worktree-only-mount caveat.
- **`multi-workspace-mounts` spec**: modify the existing "Nested worktrees portable via relative paths" requirement — it currently assumes host opt-in; rewrite to describe the container-overlay mechanism, the asymmetric on-disk state, and the host-libgit2 compatibility property the asymmetry preserves.

No new container capabilities, no Dockerfile change. The `ubuntu:26.04` base from the previous change is what unblocks this — its git 2.53 supports the relative-paths flags out of the box.

## Capabilities

### New Capabilities

*(none — this change modifies an existing capability)*

### Modified Capabilities

- `multi-workspace-mounts`: rewrites the "Nested worktrees portable via relative paths" requirement. The old version required a host-side opt-in (`git config worktree.useRelativePaths true`). The new version requires `run.sh` to inject a container-only `.git/config` overlay declaring the relative-paths extension, so no host config is needed and the host's on-disk repo config stays clean.

## Impact

- **Code**: `claude-docker/run.sh` (~25 lines of overlay loop after the existing host-config stage loop), `claude-docker/README.md` (worktree section rewritten).
- **Spec**: `openspec/specs/multi-workspace-mounts/spec.md` (one modified requirement; the prior change's three scenarios are reframed around the overlay instead of the host opt-in).
- **User-facing**: nested worktrees just work out of the box — no opt-in step, no `--relative-paths` repair needed for new worktrees. Pre-existing absolute-path worktrees still need a one-time `git worktree repair --relative-paths` from inside the container.
- **Per-repo cleanup needed (one-time, host-side)**: any repo where the user previously ran the old opt-in keeps the extension flag in its on-disk `.git/config`, which keeps blinding host gitstatusd. Cleanup steps go in the change notes — not automated, because the wrapper has no business writing to host repo configs.
- **Trade-off**: container-side `git config --local` and `git remote add` writes are ephemeral. Persistent config edits should happen on the host. This matches typical claude-docker usage (config setup host-side, code work container-side).
- **Compatibility**: zero rebuild needed; bash 3.2 compatible (counter loop, no `${!arr[@]}` on indexed arrays).
