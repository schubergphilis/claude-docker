## Why

`add-container-runtime-selection` made `run.sh` start a container from Git Bash
on Windows, but that is as far as Windows support goes. Reading the wrapper
against how Windows actually behaves turns up failures on the very first run
and in most of the opt-in flags:

- **Line endings.** The repo has no `.gitattributes`, and Git for Windows
  installs with `core.autocrlf=true`. A Windows clone therefore gets CRLF
  `entrypoint.sh` (container dies with `env: 'bash\r': No such file or
  directory`), CRLF `pins/*.env` (every sourced URL and sha256 ends in `\r`,
  so the build fails), and a CRLF `run.sh` (`$'\r': command not found`).
- **`--gh` under Git Bash.** MSYS argv conversion is (correctly) disabled, but
  the `<runtime> cp` that extracts the sidecar's CA passes its host
  destination as `/c/Users/...`, which the native engine can't resolve. Every
  proxied session aborts with "did not produce a CA certificate within 15s".
- **Identity.** Git Bash's `id -u` / `id -g` return SID-derived values such as
  `197609`, which fall outside the 65536-ID subordinate range rootless podman
  maps, so the privilege drop can fail.
- **In-container git.** NTFS bind mounts show every file as owned by
  container root, so git ≥ 2.35.2 refuses each workspace with `detected
  dubious ownership`. And Git for Windows keeps `core.autocrlf=true` in its
  *system* config, which the container never sees, so every CRLF file shows as
  modified inside the container.
- **Credential paths.** `terraform login`, uv, pip and glab keep their Windows
  config under `%APPDATA%` (pip as `pip.ini`), so `--tfe`, `--registry` and
  `--glab` silently mount nothing on Windows.

## What Changes

- Add `.gitattributes` declaring LF for all text files.
- Pass the `cp` destination through `hostpath()`, like every bind-mount source.
- Under MSYS/MINGW/Cygwin only:
  - forward `HOST_UID=1000` / `HOST_GID=1000`;
  - pass `safe.directory=/workspaces/*` via `GIT_CONFIG_COUNT` env;
  - append the host workspace's effective `core.autocrlf` to its
    container-only `.git/config` overlay;
  - look up `%APPDATA%\terraform.d\credentials.tfrc.json`, `%APPDATA%\uv\uv.toml`,
    `%APPDATA%\pip\pip.ini` and `%APPDATA%\glab-cli` before the existing
    fallbacks.
- Add `claude-docker.ps1`, a PowerShell launcher that runs `run.sh` under Git
  for Windows' bundled `bash.exe` (never WSL's), so PowerShell users don't need
  to open Git Bash. No wrapper logic is duplicated.
- Docs: a new `docs/windows.md` that covers PowerShell, WSL2 (fastest for large
  repos) and Git Bash, and documents the Git Bash specifics (TTY in mintty, installing without `ln -s`).
- A Linux-runnable unit test that runs `run.sh` under a simulated Git Bash
  (stub `uname` / `cygpath` / `id` / engine) and asserts the emitted argv.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `container-runtime`: host-path translation covers every native-executable
  path, not just bind-mount sources; new requirements for Windows identity/git
  trust, LF checkouts, and the PowerShell launcher.
- `external-cli-tools`: `--tfe` and `--glab` find their Windows locations.
- `package-managers`: `--registry` finds Windows uv and pip config.

## Impact

- **Code**: `run.sh`, new `.gitattributes`, new `claude-docker.ps1`.
- **Tests**: new `tests/test_windows_host.py` (stdlib, picked up by CI's
  existing unittest step).
- **Docs**: new `docs/windows.md`; `README.md` (pointer, `--glab` / `--tfe` paths) and `docs/auth.md` (registry paths).
- **Security posture**: unchanged. The agent still drops to a non-root UID with
  no usable capabilities; the fixed UID only replaces a synthetic number that
  never corresponded to real file ownership. `safe.directory` is scoped to
  `/workspaces/*`, which holds only the directories the user passed. No new
  credential reaches the container: each `%APPDATA%` lookup is gated on the
  same opt-in flag as its existing path, and mounted read-only.
- **Linux/macOS**: argv byte-for-byte unchanged — every new branch is gated on
  `IS_MSYS` / a non-empty `APPDATA_DIR`, which are only set under MSYS.
