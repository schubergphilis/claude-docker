# container-runtime Specification

## Purpose
TBD - created by archiving change add-container-runtime-selection. Update Purpose after archive.

## Requirements

### Requirement: Container runtime is selected, not hardcoded

`run.sh` SHALL choose the container engine at run time rather than invoking a
literal `docker`. Selection SHALL proceed as:

1. If `CLAUDE_DOCKER_RUNTIME` is set, its value is the runtime. The value SHALL
   be allowlisted to `docker` or `podman`; any other non-empty value (including
   an arbitrary binary that happens to be on PATH) SHALL cause `run.sh` to print
   an error to stderr and exit non-zero without starting a container.
2. If `CLAUDE_DOCKER_RUNTIME` is unset or empty, `run.sh` SHALL auto-detect,
   preferring `docker` and falling back to `podman`.
3. If the selected runtime is not found on PATH, `run.sh` SHALL print an error
   to stderr and exit non-zero without starting a container. When auto-detect
   finds neither engine, the error SHALL name both `docker` and `podman` and
   mention `CLAUDE_DOCKER_RUNTIME`.

The resolved runtime SHALL be invoked as `<runtime> run …` with the identical
argument list the wrapper previously passed to `docker run`.

#### Scenario: docker-first auto-detect prefers docker

- **GIVEN** `CLAUDE_DOCKER_RUNTIME` is unset
- **AND** both `docker` and `podman` are on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** the container is started via `docker run …`

#### Scenario: auto-detect falls back to podman on a podman-only host

- **GIVEN** `CLAUDE_DOCKER_RUNTIME` is unset
- **AND** `docker` is not on PATH but `podman` is
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** the container is started via `podman run …`
- **AND** no `docker: command not found` error is printed

#### Scenario: override forces podman even when docker is present

- **GIVEN** `CLAUDE_DOCKER_RUNTIME=podman`
- **AND** both `docker` and `podman` are on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** the container is started via `podman run …`

#### Scenario: invalid override is rejected before anything runs

- **GIVEN** `CLAUDE_DOCKER_RUNTIME=some-other-binary` (a value other than `docker` or `podman`)
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** `run.sh` prints an error naming the allowed values and exits non-zero
- **AND** no container is started and `some-other-binary` is never executed

#### Scenario: requested runtime missing from PATH

- **GIVEN** `CLAUDE_DOCKER_RUNTIME=podman`
- **AND** `podman` is not on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** `run.sh` prints an error that the requested runtime was not found and exits non-zero

#### Scenario: no engine installed

- **GIVEN** `CLAUDE_DOCKER_RUNTIME` is unset
- **AND** neither `docker` nor `podman` is on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** `run.sh` prints an error naming `docker`, `podman`, and `CLAUDE_DOCKER_RUNTIME`, and exits non-zero
- **AND** no `mktemp` staging directory is left on disk

### Requirement: Runtime selection defers to the help short-circuit

Runtime selection SHALL run only after wrapper-flag parsing, so the `-h`/`--help`
short-circuit (which exits 0 before any engine is required) is never blocked by
the absence of a container runtime.

#### Scenario: --help succeeds with no engine installed

- **GIVEN** neither `docker` nor `podman` is on PATH
- **WHEN** the user runs `claude-docker --help`
- **THEN** usage text is printed to stdout and the process exits 0
- **AND** no runtime-not-found error is printed

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
- vouch for every mounted workspace for git's ownership check (requirement
  *In-container git trusts only the workspaces you own*), since an NTFS mount
  carries no owner to check, and pass no git configuration through the
  environment;
- carry the host repository's effective `core.autocrlf` (as reported by the
  host's `git config --get core.autocrlf` for that workspace, which includes
  Git for Windows' system-level default) into that workspace's container-only
  `.git/config` overlay, so in-container git agrees with the host on line
  endings.

Off MSYS/MINGW/Cygwin, `run.sh` SHALL forward `id -u` / `id -g` unchanged and
SHALL NOT add the `core.autocrlf` overlay entry.

#### Scenario: Git Bash forwards a fixed non-root UID

- **GIVEN** `run.sh` runs under Git Bash, where `id -u` prints `197609`
- **WHEN** the wrapper builds the engine argv
- **THEN** it passes `HOST_UID=1000` and `HOST_GID=1000`
- **AND** the agent process inside the container runs as UID 1000, not 0

#### Scenario: in-container git works on a Windows workspace

- **GIVEN** `run.sh` runs under Git Bash and the workspace is a git repo on NTFS
- **WHEN** the agent runs `git status` in `/workspaces/<name>`
- **THEN** git does not fail with `detected dubious ownership`
- **AND** `git config --system --get-all safe.directory` lists only `/workspaces/<name>` and `/workspaces/<name>/*`

#### Scenario: host line-ending policy reaches the container

- **GIVEN** `run.sh` runs under Git Bash and the host's effective `core.autocrlf` for the workspace is `true`
- **WHEN** the agent runs `git config --get core.autocrlf` in `/workspaces/<name>`
- **THEN** it prints `true`
- **AND** `git status` does not report CRLF-checked-out files as modified

#### Scenario: Linux and macOS are unaffected

- **GIVEN** `run.sh` runs under a Linux or macOS shell
- **WHEN** the wrapper builds the engine argv
- **THEN** `HOST_UID` / `HOST_GID` equal the host's `id -u` / `id -g`
- **AND** no `safe.directory` entry is passed through `GIT_CONFIG_*` and the `.git/config` overlay gains no `core.autocrlf` entry
- **AND** a workspace is vouched for only when the host user owns it and its `.git`

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

### Requirement: Static host entries for networks without DNS

`run.sh` SHALL read `CLAUDE_DOCKER_ADD_HOSTS` from the host environment as a comma-separated list of `host:ip` entries and pass each to the runtime as `--add-host host:ip` on the agent container, so the entries land in the container's `/etc/hosts`. When the `--gh` auth-proxy sidecar is started, `run.sh` SHALL pass the same entries to the sidecar too, so it can reach its upstream.

- An entry SHALL match a hostname (letters, digits, `.` and `-`), a `:`, and an IPv4 or IPv6 address (hex digits, `.` and `:`). Any other entry SHALL make `run.sh` exit 1 with an error naming the entry, before starting any container. Unset or empty adds nothing.
- While the `--gh` sidecar is active, entries for `github.com`, `api.github.com` and `uploads.github.com` (case-insensitive) SHALL NOT be passed to the agent container, which must keep resolving them to the sidecar; `run.sh` SHALL print a one-line warning for each skipped entry. The sidecar still receives them.
- The variable SHALL NOT be forwarded into any container.

#### Scenario: Entries reach the agent container

- **GIVEN** the host exports `CLAUDE_DOCKER_ADD_HOSTS=gitlab.example.com:10.1.2.3,devops.example.com:10.1.2.4`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `getent hosts gitlab.example.com` inside the container prints `10.1.2.3`
- **AND** `getent hosts devops.example.com` inside the container prints `10.1.2.4`

#### Scenario: A malformed entry fails loudly

- **GIVEN** the host exports `CLAUDE_DOCKER_ADD_HOSTS=gitlab.example.com`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `run.sh` exits 1 with an error naming `gitlab.example.com` and starts no container

#### Scenario: The --gh sidecar keeps its hosts

- **GIVEN** the host exports `CLAUDE_DOCKER_ADD_HOSTS=github.com:140.82.121.4`
- **WHEN** user runs `claude-docker --gh ~/repo` and the sidecar starts
- **THEN** the sidecar container resolves `github.com` to `140.82.121.4`
- **AND** the agent container resolves `github.com` to the sidecar
- **AND** stderr carries a warning naming the skipped entry

### Requirement: In-container git trusts only the workspaces you own

Git's ownership check misfires inside the container, so `run.sh` SHALL decide on the host. It SHALL vouch for a workspace the host user owns along with its git directory: a `.git` directory, or the gitdir and commondir a `.git` file points to, never a `.git` symlink. Under MSYS/MINGW/Cygwin it SHALL vouch for every workspace. It SHALL print a notice for each workspace it does not vouch for.

#### Scenario: a workspace you own is accepted despite an owner mismatch

- **GIVEN** a workspace and its `.git` owned by the host user, mounted at `/workspaces/<name>`, and a repository there or in a worktree under `/workspaces/<name>/.claude/worktrees/` whose owner git sees as differing from the current user
- **WHEN** the agent runs `git rev-parse --show-toplevel` there
- **THEN** git prints the top-level path and does not fail with `detected dubious ownership`

#### Scenario: a workspace another user owns is refused

- **GIVEN** a workspace, or its git directory, owned by another host user, and not inside another workspace that is vouched for
- **WHEN** user runs `claude-docker` with it on a Linux or macOS host
- **THEN** `run.sh` prints a notice that git in the container won't trust it
- **AND** git in the session fails on it with `detected dubious ownership`, so that user's hooks and `core.fsmonitor` don't run

#### Scenario: a worktree of another user's repository is refused

- **GIVEN** a workspace you own whose `.git` file points to a gitdir another host user owns
- **WHEN** user runs `claude-docker` with it on a Linux or macOS host
- **THEN** `run.sh` does not vouch for it and prints a notice

#### Scenario: a foreign workspace inside a vouched-for one is named

- **GIVEN** a workspace another host user owns, passed inside a workspace you own
- **WHEN** user runs `claude-docker` with both
- **THEN** git in the container trusts it through the outer workspace's entry
- **AND** `run.sh` warns that it is trusted anyway, naming the outer workspace

#### Scenario: an exported GIT_CONFIG set does not drop the trust

- **GIVEN** a vouched-for workspace, and a session that exports `GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=/elsewhere`
- **WHEN** the agent runs git there
- **THEN** git still accepts the repository

#### Scenario: a repository outside /workspaces is still refused

- **GIVEN** a git repository under `/tmp` whose owner git sees as differing from the current user
- **WHEN** the agent runs git there
- **THEN** git fails with `detected dubious ownership`

### Requirement: The entrypoint writes the vouched-for workspaces to system git config

`run.sh` SHALL pass the vouched-for container paths as `CLAUDE_DOCKER_TRUSTED_WORKSPACES`, colon-separated. As root, before the privilege drop, the entrypoint SHALL add `safe.directory = <path>` and `<path>/*` to `/etc/gitconfig` for each `/workspaces/<name>` path, and refuse any other value, `*` included, with a warning. The image SHALL carry no `safe.directory`, and `run.sh` SHALL pass none through the environment.

#### Scenario: the system scope lists only the vouched-for workspaces

- **GIVEN** `claude-docker ~/repo`, where the host user owns `~/repo` and `~/repo/.git`
- **WHEN** the agent runs `git config --system --get-all safe.directory`
- **THEN** it prints exactly `/workspaces/repo` and `/workspaces/repo/*`

#### Scenario: a widening value is refused

- **GIVEN** `CLAUDE_DOCKER_TRUSTED_WORKSPACES` holds `*`, `/workspaces/*` or a path outside `/workspaces/<name>`
- **WHEN** the entrypoint runs
- **THEN** that value is not written and the entrypoint warns
