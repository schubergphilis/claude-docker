## MODIFIED Requirements

### Requirement: Container-side paths survive MSYS/MINGW argv translation

Under an MSYS/MINGW/Cygwin shell (Git Bash on Windows), `run.sh` SHALL prevent
the shell from rewriting container-side paths in the engine argv, and SHALL
translate every host path it hands to a native Windows executable — engine
bind-mount sources, engine `cp` destinations, and paths passed to the host's
native `git` — to a native Windows path form that executable accepts. Container-side paths — `/workspaces/<name>`, the `-w` working
directory, `--add-dir` values, and in-container targets under `/root` and
`/run` — SHALL reach the engine verbatim. Off MSYS/MINGW/Cygwin (Linux, macOS),
no path translation SHALL be applied and the emitted argv SHALL be unchanged
from the hardcoded-`docker` behaviour.

#### Scenario: container-side paths are not rewritten under Git Bash

- **GIVEN** `run.sh` runs under Git Bash (an MSYS/MINGW shell) on Windows
- **WHEN** the wrapper builds the engine argv
- **THEN** `/workspaces/<name>`, the `-w` value, and every `--add-dir` value are passed to the engine exactly as written (not rewritten to the MSYS/Git install prefix such as `\Program Files\Git\...`)

#### Scenario: host bind-mount sources are passed in a Windows-native form

- **GIVEN** `run.sh` runs under Git Bash on Windows
- **AND** a workspace resolves to a host path such as `/c/Users/dev/repo`
- **WHEN** the wrapper builds the workspace bind-mount argument
- **THEN** the bind-mount source is expressed in a Windows-native form the engine accepts (e.g. `C:/Users/dev/repo`), so the mount resolves instead of failing with an invalid-path error

#### Scenario: non-Windows argv is unchanged

- **GIVEN** `run.sh` runs under a Linux or macOS shell (not MSYS/MINGW/Cygwin)
- **WHEN** the wrapper builds the engine argv
- **THEN** no path translation is applied and every mount/path argument is identical to the pre-change `docker run` argv

#### Scenario: gh-proxy CA extraction lands on the host under Git Bash

- **GIVEN** `run.sh` runs under Git Bash on Windows with `--gh` and a discoverable host token
- **WHEN** the wrapper copies the sidecar's CA root out with `<runtime> cp`
- **THEN** the `cp` destination is passed in Windows-native form (e.g. `C:/Users/dev/.cache/claude-docker/host.XXXXXX/gh-proxy/root.crt`)
- **AND** the CA file is written into the session stage dir, so the sidecar starts instead of failing its 15s CA wait

## ADDED Requirements

### Requirement: Windows hosts get a working in-container identity and git

A Windows host has no POSIX ownership to preserve: under Git Bash, `id -u` /
`id -g` return synthetic values derived from the Windows SID (e.g.
`197609`/`197121`), and engine bind mounts of NTFS paths show files as owned by
container root regardless of who wrote them. Under an MSYS/MINGW/Cygwin shell,
`run.sh` SHALL therefore:

- forward `HOST_UID=1000` and `HOST_GID=1000` instead of the synthetic IDs, so
  the entrypoint's privilege drop targets a UID that fits the default
  subordinate-ID range of rootless engines (65536 IDs). The drop itself is
  unchanged — the agent SHALL still run as a non-root UID with no usable
  capabilities;
- mark only the mounted workspaces as safe for git by passing
  `safe.directory=/workspaces/*` through git's environment-based config
  (`GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>`), so
  git's ownership check does not refuse every workspace. No path outside
  `/workspaces` SHALL be marked safe;
- carry the host repository's effective `core.autocrlf` (as reported by the
  host's `git config --get core.autocrlf` for that workspace, which includes
  Git for Windows' system-level default) into that workspace's container-only
  `.git/config` overlay, so in-container git agrees with the host on line
  endings.

Off MSYS/MINGW/Cygwin, `run.sh` SHALL forward `id -u` / `id -g` unchanged and
SHALL NOT add any of the git configuration above.

#### Scenario: Git Bash forwards a fixed non-root UID

- **GIVEN** `run.sh` runs under Git Bash, where `id -u` prints `197609`
- **WHEN** the wrapper builds the engine argv
- **THEN** it passes `HOST_UID=1000` and `HOST_GID=1000`
- **AND** the agent process inside the container runs as UID 1000, not 0

#### Scenario: in-container git works on a Windows workspace

- **GIVEN** `run.sh` runs under Git Bash and the workspace is a git repo on NTFS
- **WHEN** the agent runs `git status` in `/workspaces/<name>`
- **THEN** git does not fail with `detected dubious ownership`
- **AND** `git config --get-all safe.directory` inside the container lists only `/workspaces/*`

#### Scenario: host line-ending policy reaches the container

- **GIVEN** `run.sh` runs under Git Bash and the host's effective `core.autocrlf` for the workspace is `true`
- **WHEN** the agent runs `git config --get core.autocrlf` in `/workspaces/<name>`
- **THEN** it prints `true`
- **AND** `git status` does not report CRLF-checked-out files as modified

#### Scenario: Linux and macOS are unaffected

- **GIVEN** `run.sh` runs under a Linux or macOS shell
- **WHEN** the wrapper builds the engine argv
- **THEN** `HOST_UID` / `HOST_GID` equal the host's `id -u` / `id -g`
- **AND** no `GIT_CONFIG_*` variable is passed and the `.git/config` overlay gains no `core.autocrlf` entry

### Requirement: Repository files check out with LF line endings on every host

The repository SHALL declare LF line endings for its text files in
`.gitattributes`, so a checkout on Windows — where Git for Windows defaults to
`core.autocrlf=true` — yields byte-identical `run.sh`, `entrypoint.sh`,
`Dockerfile`, and `pins/*.env` to a Linux or macOS checkout.

#### Scenario: a Windows clone builds and runs

- **GIVEN** the repository is cloned on Windows with `core.autocrlf=true`
- **WHEN** the user builds the image and runs `claude-docker` from Git Bash
- **THEN** `run.sh` does not fail with `$'\r': command not found`
- **AND** the build's pinned sha256 checks pass (no trailing `\r` in `pins/*.env` values)
- **AND** the container starts without `env: 'bash\r': No such file or directory`

### Requirement: PowerShell launcher runs the same wrapper

The repository SHALL ship `claude-docker.ps1`, a PowerShell entry point that
runs `run.sh` with the caller's arguments under the `bash.exe` bundled with Git
for Windows, so a Windows user can run `claude-docker` from PowerShell without
opening Git Bash. The launcher SHALL NOT re-implement any wrapper behaviour:
flag parsing, mounts, credential opt-ins and hardening SHALL all remain in
`run.sh`.

The launcher SHALL locate `bash.exe` relative to the `git.exe` found on PATH and
SHALL NOT invoke a bare `bash`, which on Windows commonly resolves to WSL's
`C:\Windows\System32\bash.exe`. When Git for Windows cannot be found, it SHALL
print an error naming Git for Windows and exit non-zero. It SHALL set `HOME`
(from `USERPROFILE`) and `TERM` (`xterm-256color`) for the child only when they
are unset, SHALL leave the calling session's environment unchanged, and SHALL
exit with `run.sh`'s exit code.

#### Scenario: claude-docker from PowerShell

- **GIVEN** Git for Windows is installed and the repo folder is on PATH
- **WHEN** the user runs `claude-docker C:\Users\dev\repo` in PowerShell
- **THEN** `run.sh` runs under Git for Windows' `bash.exe` with `C:\Users\dev\repo` as its workspace argument
- **AND** the container starts with `/workspaces/repo` as its working directory

#### Scenario: WSL's bash is never used

- **GIVEN** `bash` on the PowerShell PATH resolves to `C:\Windows\System32\bash.exe`
- **WHEN** the user runs `claude-docker` in PowerShell
- **THEN** the launcher runs Git for Windows' `bin\bash.exe`, not the WSL one

#### Scenario: no Git for Windows

- **GIVEN** `git.exe` is not on PATH
- **WHEN** the user runs `claude-docker` in PowerShell
- **THEN** the launcher prints an error naming Git for Windows and exits non-zero without starting a container
