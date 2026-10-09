## Why

The container has no SSH key or agent: git forges are reached with tokens only.
Yet git often goes over SSH — workspaces cloned on the host keep their
`git@host:` remotes, and glab defaults `git_protocol` to `ssh` — and fails. Over
HTTPS, git has no credential helper for GitLab, Azure DevOps or `--gh-direct`,
so switching protocol alone just trades the SSH error for a password prompt.

## What Changes

- New opt-in flag `--git-https`. With `--gh` / `--gh-direct` / `--glab`, SSH
  remotes for that forge's host are rewritten to HTTPS (`url.<https>.insteadOf`)
  and glab's `git_protocol` is set to `https`; with `--gh-direct` / `--glab` /
  `--az`, git gets a credential helper that answers with the forwarded token.
- All of it is passed as `GIT_CONFIG_*` env (command-line scope), so nothing is
  written to the persistent `~/.gitconfig`. The Git Bash `safe.directory` entry
  moves onto the same list.
- Without the flag, behaviour is unchanged.

## Capabilities

- `external-cli-tools`: ADDED *Git over HTTPS opt-in*.
- `cli-help`: MODIFIED *Help output enumerates every wrapper flag* (`--git-https`).

## Impact

- `run.sh`, `tests/bats/run.bats`, `README.md`, `docs/auth.md`. No image change.
