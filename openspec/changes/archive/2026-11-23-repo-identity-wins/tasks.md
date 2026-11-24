## 1. Spec

- [x] 1.1 ADDED `container-runtime` *In-container git identity defers to the repository's*
- [x] 1.2 `openspec validate repo-identity-wins --strict` passes

## 2. Wrapper and entrypoint

- [x] 2.1 `run.sh` `forward_git_identity`: `CLAUDE_DOCKER_GIT_USER_NAME` / `_EMAIL`, no `GIT_AUTHOR_*` / `GIT_COMMITTER_*`; help text
- [x] 2.2 `entrypoint.sh` `set_git_identity`: write `user.name` / `user.email` to `/etc/gitconfig` with `git -C /`, warn on failure, unset the variables

## 3. Docs

- [x] 3.1 `docs/usage.md` *Git identity*: system scope, the repository's identity wins, the container's `~/.gitconfig` too

## 4. Verification

- [x] 4.1 BATS: forwarded as the new variables and never as git's; written and unset; nothing forwarded writes nothing; a real commit takes the forwarded identity, then the repository's once it sets one; a dangling worktree working directory; a failed write warns and main still execs
- [x] 4.2 `bats tests/bats` and the unittest suite pass locally
