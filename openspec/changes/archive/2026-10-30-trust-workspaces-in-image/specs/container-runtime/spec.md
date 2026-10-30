## MODIFIED Requirements

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

## ADDED Requirements

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
