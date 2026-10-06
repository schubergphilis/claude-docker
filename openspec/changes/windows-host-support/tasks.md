## 1. Line endings

- [x] 1.1 Add `.gitattributes` with `* text=auto eol=lf`.

## 2. run.sh — Git Bash fixes

- [x] 2.1 Wrap the gh-proxy CA `<runtime> cp` destination in `hostpath()`.
- [x] 2.2 Add `APPDATA_DIR` (`cygpath -u "$APPDATA"`, MSYS only) next to `hostpath()`.
- [x] 2.3 `%APPDATA%` lookups for `--tfe` (`terraform.d/credentials.tfrc.json`), `--glab` (`glab-cli`), `--registry` uv (`uv/uv.toml`) and pip (`pip/pip.ini`), ahead of the existing fallbacks.
- [x] 2.4 Under MSYS, forward `HOST_UID=1000` / `HOST_GID=1000`.
- [x] 2.5 Under MSYS, pass `safe.directory=/workspaces/*` via `GIT_CONFIG_COUNT` env.
- [x] 2.6 Under MSYS, append the host workspace's effective `core.autocrlf` to its `.git/config` overlay (`git -C "$(hostpath …)"`).
- [x] 2.7 Route the `--glab` origin lookup's `git -C` through `hostpath()` too (added by #127 after this change was drafted).

## 2b. PowerShell launcher

- [x] 2b.1 Add `claude-docker.ps1`: locate Git for Windows' `bin\bash.exe` from `git.exe`, run `run.sh` with the caller's args, set `HOME`/`TERM` only when unset and restore them, propagate the exit code.
- [x] 2b.2 Static test: the launcher never invokes a bare `bash` and hands its arguments to `run.sh`.

## 3. Docs

- [x] 3.1 `docs/windows.md` (linked from the README): Windows section — PowerShell (launcher setup, execution policy, PATH), WSL2 for large repos, Git Bash specifics (TTY in mintty, install without `ln -s`, `%APPDATA%` credential lookups).
- [x] 3.2 Update the `--glab` / `--tfe` path descriptions in `README.md` and the `--registry` ones in `docs/auth.md`.

## 4. Tests (Linux-runnable)

- [x] 4.1 `tests/test_windows_host.py`: run `run.sh` with stub `uname` (MINGW64), `cygpath`, `id` and engine on PATH; assert container-side paths verbatim, Windows-form mount sources, `HOST_UID=1000`, `GIT_CONFIG_*` safe.directory, the `cp` destination form, `%APPDATA%` mounts, and the overlay's `autocrlf`.
- [x] 4.2 Same harness off-MSYS: `HOST_UID` = `id -u`, no `GIT_CONFIG_*`, no `autocrlf` in the overlay.
- [x] 4.3 `.gitattributes` test: assert `run.sh`, `entrypoint.sh`, `pins/*.env` resolve to `eol=lf`.

## 5. Validation

- [ ] 5.1 `shellcheck run.sh entrypoint.sh smoke/*.sh` and `python3 -m unittest discover -s tests -p 'test_*.py'` pass. (unittest passes, 123 tests; shellcheck not yet run — unavailable in the dev sandbox)
- [x] 5.2 `openspec validate windows-host-support --strict` passes.

## 6. Windows validation (manual, real host, before archive)

- [ ] 6.1 Fresh clone with `core.autocrlf=true`: image builds, `claude-docker` starts from Git Bash.
- [ ] 6.2 Docker Desktop and rootless podman: agent runs as UID 1000; `git status` works in a workspace and doesn't list CRLF files as modified.
- [ ] 6.3 `--gh` with a host token: sidecar starts, `gh api /user` works.
- [ ] 6.4 `--tfe`, `--glab`, `--registry` mount their `%APPDATA%` files.
- [ ] 6.5 PowerShell 7 in Windows Terminal: `claude-docker C:\path\to\repo` starts the container; `--claude-dir="$env:USERPROFILE\.claude-docker"` is honoured; exit code propagates; `$env:HOME`/`$env:TERM` unchanged afterwards.
- [ ] 6.6 WSL2 route: `run.sh` from a WSL distro with a repo in the WSL filesystem works unchanged.
