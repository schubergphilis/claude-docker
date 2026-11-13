# Tasks

- [x] 1.1 `entrypoint.sh`: `trust_workspaces` runs `git -C /`, so a dangling `.git` pointer in the working directory doesn't abort startup. Verify with bats.
- [x] 1.2 `run.sh`: `build_git_trust` keeps which workspaces it vouched for (`GIT_VOUCHED`).
- [x] 1.3 `run.sh`: `worktree_common_dir` and `normalize_path` find the repository git directory a worktree's `.git` file leads to, as the container will look it up; relative pointers and submodules are left out, and so is anything not laid out as a real worktree of a real git directory that names the workspace back (a pointer planted from the container, a symlink between gitdir and repository). Verify with bats.
- [x] 1.4 `run.sh`: `build_worktree_gitdirs` asks once per repository not inside a mounted workspace, mounts its git directory `:ro` at that path on yes, warns on no; `CLAUDE_DOCKER_WORKTREE_GITDIR` (`ask`/`ro`/`off`); no terminal declines. Verify with bats.
- [x] 1.5 `validate_opts`: refuse an unknown `CLAUDE_DOCKER_WORKTREE_GITDIR`. Verify with bats.
- [x] 1.6 Docs: `docs/usage.md` (Git worktrees), `docs/security.md`.
- [x] 1.7 Run the bats suite and shellcheck; `openspec validate worktree-gitdir-ro --strict`.
- [x] 1.8 On a Mac with Docker Desktop or Colima: `claude-docker <worktree>` outside its repo, accept, and check `git status`/`log`/`diff` work and `git commit` fails.
- [x] 1.9 `/opsx:archive` (syncs `openspec/specs/`).
