## Why

The forge flags forward a token that the CLIs use, but git itself has no
credential helper. Over HTTPS, `git push` under `--glab` fails with
"could not read Username" even with `GITLAB_TOKEN` set, and `--gh-direct` and
`--az` have the same gap. (`--gh` is fine: the sidecar injects auth for
`github.com`.)

SSH remotes are a separate problem and stay out of scope. The container has no
SSH key or agent on purpose, and switching a remote to HTTPS is a one-time fix
the user makes outside claude-docker (#158).

## What Changes

- `--gh-direct`, `--glab` and `--az` each add a git credential helper scoped
  to their own forge host: `gh auth git-credential` for `github.com`,
  `glab auth git-credential` for the GitLab host, and a helper that answers
  with `AZURE_DEVOPS_EXT_PAT` from the container env for the Azure DevOps host.
  No new flag.
- The helpers are passed as `GIT_CONFIG_*` env (command-line scope), on one
  list with the Git Bash `safe.directory` entry, so `~/.gitconfig` is untouched.
- `docs/auth.md` gains *Git over HTTPS* and an *SSH remotes* note covering
  GitHub, GitLab and Azure DevOps.

## Capabilities

- `external-cli-tools`: ADDED *Git credential helper per forge host*.
- `container-runtime`: MODIFIED *Windows hosts get a working in-container
  identity and git*. The Linux/macOS scenario no longer says no `GIT_CONFIG_*`
  variable is passed, only that `safe.directory` isn't.

## Impact

- `run.sh`, `tests/bats/run.bats`, `docs/auth.md`. No image change.
