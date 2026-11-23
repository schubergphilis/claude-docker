## Why

`run.sh` forwards the host's global `user.name` / `user.email` as
`GIT_AUTHOR_*` / `GIT_COMMITTER_*` env. Those override every git config file,
so a repository that sets its own identity (a work address, say) commits under
the global one in a session, unlike on the host. That breaks guarantee 3 agreed
in #1: "at start the session uses your repo's config, and from your global
config only `user.name` and `user.email`."

## What Changes

- `run.sh` passes the identity as `CLAUDE_DOCKER_GIT_USER_NAME` /
  `CLAUDE_DOCKER_GIT_USER_EMAIL` instead of git's own env variables.
- The entrypoint, as root before the privilege drop, writes them to
  `/etc/gitconfig` (`user.name`, `user.email`), runs git from `/` so a dangling
  worktree working directory doesn't stop it, and unsets the variables before
  starting claude. A failed write warns and doesn't stop the session.
- Git's own precedence then applies: the repository's identity, then the
  container's `~/.gitconfig`, then the forwarded one.
- Docs: `docs/usage.md` *Git identity* and the `--help` text.

## Capabilities

### Modified Capabilities

- `container-runtime`: ADDED *In-container git identity defers to the repository's*.

## Impact

- `run.sh` (`forward_git_identity`, help text), `entrypoint.sh`
  (`set_git_identity`), `tests/bats/run.bats`, `tests/bats/entrypoint.bats`,
  `docs/usage.md`.
- A repository with its own identity now commits under it in a session. An
  identity a session once set in the container's `~/.gitconfig` (on the
  `claude-code-root` volume) now wins over the forwarded one too.
