## Why

`--git-https` rewrites GitHub and GitLab SSH remotes but leaves Azure DevOps ones
alone, so with `--az --git-https` git still goes over SSH and fails (#158). Azure
DevOps SSH and HTTPS paths differ — Services drops `_git/` from the SSH path,
Server keeps it but the HTTPS URL may sit under a virtual directory — so a
single host-wide `insteadOf` can't map them.

## What Changes

- With `--az --git-https`, each Azure DevOps SSH project (Services) or collection
  (Server) prefix found in the workspaces' remotes is rewritten to its HTTPS
  form, so every repo of that project / collection goes over HTTPS with the PAT.
- Only for the host the PAT credential helper answers for.
- The workspace git-config lookup used by `--glab` token discovery moves into a
  shared `ws_git_config` helper.

## Capabilities

- `external-cli-tools`: MODIFIED *Git over HTTPS opt-in*.

## Impact

- `run.sh`, `tests/bats/run.bats`, `README.md`. No image change.
