# Windows

[← Back to the README](../README.md)

Three routes work.

**PowerShell.** Run `claude-docker` straight from PowerShell (in Windows Terminal) against the Windows `docker.exe`/`podman.exe`. [`claude-docker.ps1`](../claude-docker.ps1) is a thin launcher: it runs `run.sh` with the `bash.exe` that ships with Git for Windows, so you need Git for Windows installed but never have to open Git Bash, and every flag works the same. Everything under "Git Bash" below applies, because that's what runs underneath — except the mintty TTY caveat, since PowerShell runs in a real console. One-time setup, from the repo folder:

```powershell
podman build --format docker -t claude-code:local .
# Put the repo folder on your user PATH so `claude-docker` resolves to claude-docker.ps1
$p = [Environment]::GetEnvironmentVariable('Path', 'User')
[Environment]::SetEnvironmentVariable('Path', "$p;$PWD", 'User')
# Only if `Get-ExecutionPolicy` says Restricted (the Windows client default):
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

PowerShell runs any `.ps1` file on `PATH` as a command, so once the repo folder is there, typing `claude-docker` runs `claude-docker.ps1` — no alias or profile edit needed. The `SetEnvironmentVariable` call writes your user `PATH` permanently (it lives in the registry), but terminals that are already open keep the copy they started with, so open a new one, then:

```powershell
claude-docker                                         # current folder
claude-docker C:\Users\me\dev\app C:\Users\me\dev\lib
claude-docker --claude-dir="$env:USERPROFILE\.claude-docker" C:\Users\me\dev\app
$env:CLAUDE_DOCKER_CONFIG_DIR = "$env:USERPROFILE\.claude-docker"   # same, for the session
```

Windows paths (`C:\...`) are accepted anywhere `run.sh` takes a path. `~` inside `--claude-dir` / `CLAUDE_DOCKER_CONFIG_DIR` means `%USERPROFILE%`. Don't run `bash run.sh` from PowerShell yourself: a bare `bash` there is usually WSL's (`C:\Windows\System32\bash.exe`), which runs the script inside Linux with a different home folder; the launcher avoids it on purpose.

**WSL2.** Clone this repo and your projects into the WSL filesystem (`~/…` inside the distro, not `/mnt/c/…`) and run `claude-docker` from the WSL shell, against Docker Desktop's WSL integration or podman. `run.sh` sees a plain Linux host, so everything behaves exactly as on Linux — real UIDs, Linux git config, and native ext4 file access, which is far faster than bind-mounting NTFS; prefer it for large repos. Note that inside WSL, `~/.claude`, `~/.aws` etc. are the *WSL* home's copies, not your Windows profile's.

**Git Bash.** Run `claude-docker` from Git Bash (MSYS/MINGW) against the Windows `docker.exe`/`podman.exe`, with projects on NTFS. The wrapper handles the Windows-specific parts itself:

- MSYS's automatic POSIX→Windows argv rewriting is disabled, and every host path handed to a native executable (mount sources, `cp` destinations, `git -C`) is translated with `cygpath`, so container-side paths reach the engine intact — no `invalid option type "\Program Files\Git\workspaces\..."`.
- The container user is UID/GID `1000`, not Git Bash's synthetic SID-derived `id -u` (e.g. `197609`, outside rootless podman's ID range). NTFS mounts have no real POSIX ownership, so nothing on the host is affected; the agent still runs non-root.
- Those mounts show every file as owned by root, which trips git's ownership check, so `safe.directory=/workspaces/*` is passed to in-container git (scoped to the mounted workspaces only).
- Each workspace's effective `core.autocrlf` (Git for Windows sets `true` system-wide) is carried into its container-only `.git/config` overlay, so in-container `git status` doesn't flag every CRLF file as modified.
- `--tfe`, `--glab` and `--registry` look under `%APPDATA%` first (`terraform.d\credentials.tfrc.json`, `glab-cli\`, `uv\uv.toml`, `pip\pip.ini`), then fall back to the Linux paths.

Git Bash caveats:

- **Install:** `ln -s` in Git Bash makes a *copy* unless Windows symlinks are enabled, so `run.sh` updates won't reach `~/bin/claude-docker`. Use a one-line forwarder instead: `printf '#!/usr/bin/env bash\nexec "%s/run.sh" "$@"\n' "$(pwd)" > ~/bin/claude-docker`.
- **`the input device is not a TTY`:** Git Bash's default mintty terminal hands native programs a pipe, not a console, unless pseudo-console support is on. Run from Windows Terminal, or enable *Options → Terminal → "Enable experimental support for pseudo consoles"* in mintty.
- **Statusline:** a host `statusline-command.sh` saved with CRLF line endings fails under the container's `sh` — save it with LF.

The repo's `.gitattributes` forces LF checkouts, so a Windows clone builds as-is even with `core.autocrlf=true`.
