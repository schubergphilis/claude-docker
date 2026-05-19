## 1. Implement the overlay loop in `run.sh`

- [x] 1.1 After the existing stage-based host-config mounts (settings.docker.json mount line) and before the docker run command, add a counter loop iterating `SEEN_NAMES`/`SEEN_PATHS` (bash 3.2 compatible — no `${!arr[@]}`)
- [x] 1.2 For each workspace where `[ -f "$ws_abs/.git/config" ]` evaluates true, `cp` the host's `.git/config` to `$stage/git-config-<name>` and append a heredoc containing a `[core] repositoryformatversion = 1` section plus `[extensions] relativeWorktrees = true` and `[worktree] useRelativePaths = true`
- [x] 1.3 Add `-v $stage/git-config-<name>:/workspaces/<name>/.git/config` to `MOUNT_ARGS` (writable, NOT `:ro`)
- [x] 1.4 Add a comment block explaining the host/container asymmetry, the libgit2 + gitstatusd interaction, the v0→v1 bump requirement, and the ephemeral-writes trade-off

## 2. Update the README

- [x] 2.1 Rewrite the "Git worktrees" section: lead with "no host config change needed — claude-docker overlays the necessary config inside the container automatically"
- [x] 2.2 Document the trade-off (container-side `git config` writes are ephemeral)
- [x] 2.3 Document the worktree-only-mount caveat (overlay only applies to workspaces whose `.git` is a directory)
- [x] 2.4 Keep the "Fallback — `git worktree repair`" subsection but narrow its trigger to the sibling-flattened case (since the host-git-< 2.48 case no longer applies — the wrapper handles it)
- [x] 2.5 Remove the host opt-in commands (`git config worktree.useRelativePaths true`, `git worktree repair --relative-paths`) from the recommended path; mention them only as a remediation step for pre-existing absolute-path worktrees, run from inside the container

## 3. Update the spec

- [x] 3.1 In `openspec/changes/container-git-config-overlay/specs/multi-workspace-mounts/spec.md`, use a `## MODIFIED Requirements` block for the "Nested worktrees portable via relative paths" requirement
- [x] 3.2 The modified requirement removes the "host opted in" precondition; replaces it with "`run.sh` injects a container-only `.git/config` overlay declaring the extension and the `useRelativePaths` setting"
- [x] 3.3 Add a scenario documenting that the host's on-disk `.git/config` is NOT modified by any container-side git operation (the key correctness property)
- [x] 3.4 Update the round-trip scenarios to reflect the new mechanism (no host opt-in step, no `--relative-paths` repair step for new worktrees)

## 4. Per-repo cleanup notes (not automated)

- [ ] 4.1 Document in change notes (proposal Impact section already covers this): for any repo where the user previously ran the old host opt-in, run `git config --unset extensions.relativeWorktrees && git config --unset worktree.useRelativePaths` on the host to restore gitstatusd visibility
- [ ] 4.2 Note: there is also a stale `hooksPath = /workspaces/claude-shared/.git/hooks` (container path) in at least one local repo's host config — separate cleanup item, not in this change's scope

## 5. Verify

- [x] 5.1 End-to-end test: create a repo, replace `.git/config` with the augmented overlay, run `git worktree add`, confirm relative paths in both link files and confirm the overlay file is unchanged afterwards
- [x] 5.2 Counter-test: confirm the env-var (`GIT_CONFIG_COUNT`) alternative corrupts the on-disk config — used to justify the file-overlay approach in design.md
- [ ] 5.3 Container smoke test on the user's host: rebuild image (no Dockerfile changes), start claude-docker mounting `claude-shared`, run `git config --get extensions.relativeWorktrees` inside (expect `true`), check host's `.git/config` from another terminal (expect no extension keys), `git worktree add .claude/worktrees/test-overlay -b test-overlay` inside, then `cd` into that worktree from the host and confirm p10k shows the branch
- [ ] 5.4 Bash 3.2 verification: dry-run `bash -n run.sh` and exercise the overlay loop with macOS system bash if available
