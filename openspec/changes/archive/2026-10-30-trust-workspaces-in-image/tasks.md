## 1. Spec

- [x] 1.1 MODIFIED *Windows hosts get a working in-container identity and git*: every workspace vouched for; no `GIT_CONFIG_*`
- [x] 1.2 ADDED *In-container git trusts only the workspaces you own* and *The entrypoint writes the vouched-for workspaces to system git config*
- [x] 1.3 MODIFIED `external-cli-tools` *Git credential helper per forge host*: no `safe.directory` on the `GIT_CONFIG_*` list
- [x] 1.4 `openspec validate trust-workspaces-in-image --strict` passes

## 2. Wrapper, entrypoint and image

- [x] 2.1 `run.sh` `build_git_trust`: vouch for workspaces the host user owns along with their git directory (`.git`, or a `.git` file's gitdir and commondir; never a `.git` symlink); every workspace under MSYS; a notice for the rest, and a warning for a foreign one nested in a vouched-for one; pass `CLAUDE_DOCKER_TRUSTED_WORKSPACES`
- [x] 2.2 `run.sh` `detect_msys`: stop passing `GIT_CONFIG_*`
- [x] 2.3 `entrypoint.sh` `trust_workspaces`: write `<path>` and `<path>/*` to `/etc/gitconfig` for each `/workspaces/<name>`; refuse anything else with a WARN; a failed write stops the entrypoint
- [x] 2.4 Dockerfile: no `safe.directory` in the image

## 3. Docs

- [x] 3.1 `docs/usage.md` *File ownership*: workspaces you own are trusted; another user's are refused, with a notice
- [x] 3.2 `docs/security.md`: the ownership check still protects against a workspace another host user owns
- [x] 3.3 `docs/windows.md`: every workspace is trusted on Windows

## 4. Verification

- [x] 4.1 BATS: `build_git_trust` (owned, foreign workspace, foreign `.git`, no `.git`, none owned, Windows), `trust_workspaces` (written, nothing passed, every refused form, failed write), `check_git_trust` branches; unittest: Windows passes every workspace and no `GIT_CONFIG_*`
- [x] 4.2 Smoke `check_git_trust`: system scope lists exactly the smoke workspace and its `/*`; a forced owner mismatch is accepted under it (also after a `GIT_CONFIG_*` export) and refused under `/tmp`; setup failures are FAILs, and the temp repos are always removed
- [x] 4.3 shellcheck, `bats tests/bats`, unittest suite pass locally; hadolint and the smoke cells run in CI
