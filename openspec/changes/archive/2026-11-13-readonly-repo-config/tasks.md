## 1. Spec

- [x] 1.1 MODIFIED `multi-workspace-mounts` *Nested worktrees portable via a container-only git config overlay*: the overlay is read-only
- [x] 1.2 ADDED `multi-workspace-mounts` *Repo config is read-only in a session*
- [x] 1.3 MODIFIED `multi-workspace-mounts` *Host path map on request* and *Host path map keeps the user's append*: the repo config note shares the flag
- [x] 1.4 `openspec validate readonly-repo-config --strict` passes

## 2. Wrapper and image

- [x] 2.1 `run.sh` `stage_git_overlays`: mount `:ro`, set `GIT_CONFIG_RO`, one stderr line when any overlay is mounted
- [x] 2.2 `run.sh` `add_claude_flags`: the repo config note, after the host path map and before the user's last `--append-system-prompt`, in one flag
- [x] 2.3 `Dockerfile`: `git config --system branch.autoSetupMerge false`

## 3. Docs

- [x] 3.1 `docs/usage.md`: repo config is read-only; `push -u`, branch tracking, `remote add`/`set-url`/`config --local`; the start line and the note
- [x] 3.2 `docs/auth.md`: `set-url` on the host points there

## 4. Verification

- [x] 4.1 BATS: `:ro` mount, one notice for several overlays, none without; the note alone, and between the map and the user's text in one flag
- [x] 4.2 Smoke (Docker, every cell): the workspace is a repo; overlay mounted `ro`; `branch.autoSetupMerge` is `false`; `git config --local` fails with `could not write config file`; an in-place write fails; the host file is unchanged (runs in CI)
- [x] 4.3 `bats tests/bats/run.bats tests/bats/smoke.bats` pass locally
