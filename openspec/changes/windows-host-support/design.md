## Context

`run.sh` detects Git Bash (`uname -s` → `MINGW*`/`MSYS*`/`CYGWIN*`, `IS_MSYS=1`),
disables MSYS argv conversion and translates bind-mount sources with
`hostpath()` (`cygpath -m`). Everything else in the wrapper assumes a
macOS/Linux host: POSIX UIDs that mean something for file ownership, git whose
config the container can reproduce from the repo alone, and XDG/`~` config
locations.

Windows has two viable routes:

1. **WSL2** — clone into the WSL filesystem, run `run.sh` inside the distro
   against Docker Desktop's WSL integration or podman. `uname` is `Linux`,
   `id -u` is a real UID (1000), git's system config is Linux's, and file access
   is ext4-fast. This is the Linux code path; it needs documentation, not code.
2. **Git Bash** — run `run.sh` from MINGW against the Windows `docker.exe` /
   `podman.exe`, with repos on NTFS. This is what this change fixes.

## Goals / Non-Goals

**Goals:** a Windows clone builds; the Git Bash route runs every opt-in flag;
in-container git works on NTFS workspaces; macOS/Linux argv unchanged.

**Non-Goals:**

- A PowerShell *port* of `run.sh`. The wrapper is ~900 lines of
  security-relevant logic; two implementations would drift. PowerShell is
  served by a launcher instead (D6).
- Detecting mintty-without-ConPTY and auto-wrapping in `winpty`. Detection is
  unreliable and `winpty` breaks under Windows Terminal; documented instead.
- A Windows CI job. GitHub's `windows-latest` runners cannot run Linux
  containers; the argv-level simulation test covers the wrapper logic, and a
  real Git Bash job running it is a possible follow-up.
- Performance of NTFS bind mounts — addressed by recommending WSL2.

## Decisions

### D1: `.gitattributes` with `* text=auto eol=lf`

Forces LF in the working tree regardless of `core.autocrlf`. Covers
`entrypoint.sh` (copied into the image), `pins/*.env` (sourced by the
Dockerfile), `run.sh`, and the Dockerfile's heredocs in one line. Binary files
(the PNG) are auto-detected and untouched.

### D2: Fixed `HOST_UID=1000` / `HOST_GID=1000` under MSYS

The synthetic Git Bash IDs carry no ownership meaning on NTFS mounts, and they
fall outside rootless podman's default subordinate range. 1000 is the
conventional first user UID, is inside every default range, and the Dockerfile
already frees it (`userdel ubuntu`). Rejected: forwarding `0` — that takes the
entrypoint's legacy run-as-root path and would weaken the posture. Rejected: a
new override knob — no case needs another value yet.

Existing volumes chowned to the old synthetic UID are fixed up by the
entrypoint's chown walk on the next start.

### D3: `safe.directory=/workspaces/*` via `GIT_CONFIG_COUNT`

git only honours `safe.directory` from system, global or command-line scope;
`GIT_CONFIG_COUNT`/`KEY`/`VALUE` env is command-line scope, and `runuser`
(without `-l`) preserves the environment, so it reaches the agent. The trailing
`/*` glob (git ≥ 2.46; the image ships git from Ubuntu 26.04) covers every
workspace and nothing outside `/workspaces`. Rejected: writing
`/etc/gitconfig` in the entrypoint — it would apply on macOS/Linux too, where
ownership is real and the check is meaningful.

MSYS-only because on macOS (virtiofs) and Linux ownership matches `HOST_UID`,
and WSL2's `/mnt/c` drvfs shows files as the WSL user (also 1000).

### D4: `core.autocrlf` into the per-workspace overlay

The overlay is already a per-repo, container-only `.git/config` copy; appending
`[core] autocrlf = <value>` there scopes the host's line-ending policy to exactly
that repo and needs no new mount. The value comes from host
`git -C <ws> config --get core.autocrlf`, which resolves all scopes including
Git for Windows' system config. `-C` takes `hostpath()` because `git.exe` is a
native executable and argv conversion is off. Unset → nothing appended.
Workspaces without a `.git` directory (worktrees) get no overlay, same as today.

### D5: `%APPDATA%` lookups before existing fallbacks

`APPDATA_DIR=$(cygpath -u "$APPDATA")`, set only under MSYS. Each lookup is
inserted in the existing if/elif chain for its flag, so the opt-in gate,
read-only mount, and container target are unchanged; the old `~` paths remain
as fallbacks. pip's Windows `pip.ini` is the same INI format as `pip.conf` and
mounts at the same container path.

### D6: PowerShell via a launcher, `claude-docker.ps1`

Users who live in PowerShell shouldn't have to open Git Bash. The launcher
locates Git for Windows' `bin\bash.exe` from `git.exe`'s location and runs
`run.sh` with the caller's arguments, so there is one implementation of every
flag and control. Three details matter:

- It never invokes a bare `bash`: in PowerShell that usually resolves to
  `C:\Windows\System32\bash.exe`, i.e. WSL, which would run the wrapper inside a
  Linux distro with a different home and no Windows engine.
- It sets `HOME` (from `USERPROFILE`) and `TERM` (`xterm-256color`) only when
  unset — Git Bash's own launcher sets both, a bare `bash.exe` may not — and
  restores them afterwards, so the PowerShell session is unchanged.
- It runs inside a real Windows console, so `-it` works without the mintty
  pseudo-console caveat.

Rejected: a `.cmd` shim (cmd's `%*` re-parses `&`, `^`, `%` in arguments), and a
native PowerShell port (see Non-Goals).

## Risks / Trade-offs

- **PowerShell launcher is untested by CI** (no pwsh on the runner); covered by
  a static test for the WSL-bash invariant and the manual checklist.
  Windows PowerShell 5.1 mangles native arguments containing embedded quotes;
  PowerShell 7.3+ passes them correctly.
- **Unverified on real Windows.** D2/D3 rest on documented Docker Desktop and
  rootless-podman behaviour, not a reproduction. Tasks include a manual
  checklist on a real host before archive.
- **glab location varies by version** (`%APPDATA%\glab-cli` in current releases,
  `~/.config/glab-cli` in older ones); both are checked.
- **`GIT_CONFIG_COUNT` collides** with a user-set value inside the container —
  acceptable; the agent can extend it.
