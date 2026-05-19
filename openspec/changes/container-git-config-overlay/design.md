## Context

The previous change (`worktree-relative-paths`, archived) instructed users to set `worktree.useRelativePaths = true` on the host. Side effect: as soon as `git worktree add` (or `git worktree repair --relative-paths`) runs, git writes `extensions.relativeWorktrees = true` and bumps `core.repositoryformatversion` to 1 in the on-disk `.git/config`. Confirmed by direct test: even with the flag set only via `GIT_CONFIG_COUNT` env vars, `git worktree add` persists both keys to the repo's on-disk config — git treats the extension as a property of the repo, not the invocation.

The repo-config persistence is what blinds older libgit2-based readers. Per the git repository-extensions contract, a v1 repo declaring an unknown extension MUST be rejected by readers that don't understand it. `gitstatusd` (the daemon Powerlevel10k uses for its branch indicator) bundles libgit2 v1.5.4 (Feb 2022); the `relativeWorktrees` extension was added Jan 2025. Result: the host prompt looks like the user isn't in a git repo. Upstream `gitstatusd` v1.5.5 (latest, Mar 2024) still bundles the old libgit2; the bump-tracking issue has had no movement in a year.

The fix isn't to wait on `gitstatusd` — it's to never put the extension flag on the host side in the first place. The container has its own filesystem view, so a bind-mount that overlays just `.git/config` gives us a path-isolated divergence: container reads the augmented config and writes relative paths; host reads the unmodified config and opens the repo fine.

## Goals / Non-Goals

**Goals:**

- Inside the container, `git worktree add <nested-path>` writes relative paths into both worktree link files (`<repo>/.git/worktrees/<name>/gitdir` and `<worktree>/.git`).
- On the host, `gitstatusd`/libgit2 opens the repo normally (no extension flag present in host-visible `.git/config`).
- Worktrees created inside the container are usable from the host without `git worktree repair`.
- Zero host config modifications. No on-disk write to any host `.git/config` from the wrapper.

**Non-Goals:**

- Fixing libgit2 / gitstatusd upstream. (Out of our hands; the workaround makes the upstream issue moot for our use case.)
- Persisting container-side `git config` edits back to the host. Accepted as a trade-off; documented.
- Supporting workspaces where only the worktree (not its main repo) is mounted. The overlay can't apply because `.git/config` doesn't exist as a regular file in that path; documented.

## Decisions

### 1. File overlay, not `GIT_CONFIG_COUNT` env-var injection

Considered injecting `extensions.relativeWorktrees=true` + `worktree.useRelativePaths=true` via `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_*` / `GIT_CONFIG_VALUE_*` env vars — simpler, no per-workspace stage files, no writable-overlay footgun. **Rejected.** Direct test: with the flags set only via env vars, the first `git worktree add` inside the container writes `extensions.relativeWorktrees = true` AND bumps `repositoryformatversion = 1` to the on-disk `.git/config`. Git treats the extension as a repository property; if the parsed config has it set but the on-disk config doesn't, git "fixes" the on-disk config. End result: host's `.git/config` is corrupted with the extension flag on the first container-side worktree operation — defeats the whole purpose.

The file-overlay approach avoids this because the container sees a `.git/config` that already has the extension declared. Git has no reason to write it again — from git's perspective inside the container, it's already there.

### 2. Bump `core.repositoryformatversion` in the overlay

A v0 repo declaring an extension fails with `warning: repo version is 0, but v1-only extension found: relativeworktrees / fatal: not in a git directory`. The overlay must include a second `[core]` section bumping the version to 1 (git's config parser is last-value-wins for same-key entries, so appending a second `[core]` section is sufficient and doesn't require parsing or rewriting the existing one). Verified by direct test: container-side git operations succeed; host's on-disk `.git/config` remains v0 because the overlay file is what the container reads, not the underlying file.

### 3. Per-workspace overlay files, keyed by container basename

Each workspace gets its own `$stage/git-config-<name>` because each workspace has its own `.git/config` content. The existing basename-collision guard (`run.sh:137-148`) already ensures `<name>` is unique within a session, so there's no overlay-file collision risk. Pattern matches the existing `$stage/<item>` staging used for `agents`/`commands`/`skills` (`run.sh:261-279`).

### 4. Skip workspaces where `.git` is a pointer file

Worktrees have `.git` as a file pointing into the main repo's `.git/worktrees/<name>/`, not as a directory containing `config`. The overlay can't be applied there. The check is `[ -f "$ws_abs/.git/config" ]` — file (regular file) only, not directory or pointer. Worktrees mounted alongside their main repo resolve through the main repo's overlay anyway, since the worktree's link file points into the main repo's `.git/worktrees/<name>/` directory which lives inside the main repo mount.

When the user mounts ONLY a worktree (no main repo), no overlay is created and the worktree falls back to the existing `git worktree repair` workflow. Documented in the README.

### 5. Overlay is writable, not `:ro`

Container-side `git remote add`, `git branch --set-upstream-to`, etc., write to `.git/config`. Mounting the overlay `:ro` would error those out, which is unfriendly. Mounting writable lets them succeed against the stage copy, which is then destroyed by `run.sh`'s existing trap at exit.

Trade-off: writes to the local-repo config don't persist. This is fine because (a) typical claude-docker usage already pushes config setup to the host, (b) container-side branch/remote work is mostly transient (clone, work, push, exit), and (c) the alternative (silent failures via `:ro`) is strictly worse than silent discard.

If a future use case requires persistence, the right answer is probably a separate command or flag — not making the overlay sync back to the host file at exit, which has race-condition baggage.

### 6. Placement: after stage is created, before MOUNT_ARGS is finalised

The overlay loop needs `$stage` (created by `mktemp -d` at `run.sh:256`) and needs to add to `MOUNT_ARGS` before docker run. Placed after the existing host-config (agents/commands/skills/CLAUDE.md/statusline/settings.docker.json) staging, before the persistent-volume prepend at `run.sh:342`. This puts all stage-based mounts in one contiguous block.

### 7. bash 3.2 compatibility: counter loop, not `${!arr[@]}`

`run.sh` runs on macOS system bash 3.2 (per existing comments at `run.sh:129-132`). The new overlay loop uses the same counter-loop pattern (`n=${#SEEN_NAMES[@]}; i=0; while [ "$i" -lt "$n" ]; do ...; i=$((i + 1)); done`) as the existing collision-check loop at `run.sh:141-149`.

## Risks / Trade-offs

- **[Ephemeral local-config writes]** Container-side `git config --local <key> <value>`, `git remote add ...`, `git branch --set-upstream-to ...` and other operations that write to `.git/config` succeed but don't persist past the container session. → Mitigation: documented in README. Most users do not need persistent local-config edits from inside the container.
- **[Host-config divergence during session]** If the user edits the host's `.git/config` while a container is running (e.g. `git config user.email ...` in another terminal), the container won't see it. → Accepted. The window is short (container lifetime), and the consequence is at most "the container missed a config change" — not data loss or corruption.
- **[Pre-existing absolute-path worktrees]** Worktrees created before this change still have absolute paths in their link files and remain broken across host/container. → Mitigation: documented one-time fix is `git worktree repair --relative-paths <worktree>` from inside the container, which writes relative paths back.
- **[Pre-existing extension-flag pollution on the host]** Repos where the user followed the previous (now-retracted) host opt-in have `extensions.relativeWorktrees = true` AND `worktree.useRelativePaths = true` in their on-disk `.git/config`. These keep blinding host gitstatusd. → Mitigation: documented cleanup (`git config --unset extensions.relativeWorktrees && git config --unset worktree.useRelativePaths`) in the change notes. Not automated; the wrapper has no business writing to host repo configs.
- **[Sibling-flattened mounts]** Unchanged from the previous design. The overlay can declare the extension, but the worktree's relative offset to the repo's `.git/worktrees/<name>/` is broken by the basename-flattening mount; `git worktree repair` (no flag) is still required. Covered by the existing "Sibling worktrees supported" requirement.
- **[Bare repos]** A bare repo has `config` at the root (no `.git/` directory). The overlay's `[ -f "$ws_abs/.git/config" ]` check evaluates false, so no overlay is created. Accepted — claude-docker's usage pattern is non-bare working trees, and bare-repo workflows don't typically use worktree link files in a way that the overlay would help.

## Verification

End-to-end test executed during development (with `git 2.53.0`):

1. Create a repo, copy its `.git/config` to a stage file, append the four-line overlay (`[core] repositoryformatversion = 1; [extensions] relativeWorktrees = true; [worktree] useRelativePaths = true`).
2. Replace the repo's `.git/config` with the stage file (simulates the bind mount).
3. Run `git worktree add ../wt -b wt`. Inspect the on-disk `.git/config` afterwards — confirm git did NOT add or modify any of the appended sections.
4. Inspect `.git/worktrees/wt/gitdir` and `../wt/.git` — confirm both contain relative paths.

Result: both link files relative, on-disk overlay unchanged after worktree creation. Confirmed working.

Counter-test for the env-var alternative (rejected design):

1. Same repo, no config modification on disk.
2. Run `GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=extensions.relativeWorktrees GIT_CONFIG_VALUE_0=true GIT_CONFIG_KEY_1=worktree.useRelativePaths GIT_CONFIG_VALUE_1=true git worktree add ../wt-env -b wt-env`.
3. Inspect `.git/config` afterwards — `extensions.relativeWorktrees = true` and `repositoryformatversion = 1` have been written to the file.

Result: env-var injection silently corrupts the host on-disk config. Rejected.
