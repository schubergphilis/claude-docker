## 1. Spec

- [x] 1.1 ADDED `container-runtime` *In-container git compares minimal stat data*
- [x] 1.2 `openspec validate git-check-stat-minimal --strict` passes

## 2. Entrypoint

- [x] 2.1 `entrypoint.sh` `relax_git_stat`: set `core.checkStat = minimal` in `/etc/gitconfig` after `trust_workspaces`, on every host; a failed write is a WARN

## 3. Docs

- [x] 3.1 `docs/usage.md` *File ownership*: what the setting does, why, the trade-off and how to revert it

## 4. Verification

- [x] 4.1 BATS: `relax_git_stat` (set by `main` next to the trust entries, one entry after two runs, failed write warns and `main` still execs); `check_git_stat` (pass and fail)
- [x] 4.2 Smoke `check_git_stat`: the system scope prints exactly `minimal`
- [x] 4.3 Measured on a Docker Desktop mount (git 2.53.0): `git rebase --force-rebase HEAD~1` on a clean detached HEAD succeeds 3 of 5 times by default and 5 of 5 with `core.checkStat = minimal` in the system config
- [x] 4.4 shellcheck and the two BATS files pass locally; hadolint and the smoke cells run in CI
