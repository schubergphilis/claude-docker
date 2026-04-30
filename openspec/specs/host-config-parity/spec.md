# host-config-parity

## Purpose

Make the container feel like the user's host Claude Code: same statusline, skills, agents, commands, global preferences, and a container-specific `settings.docker.json` when the user provides one — without copying macOS-only configuration or host-filesystem hooks that would misfire inside the Linux container.

The host config directory defaults to `~/.claude` but is configurable via `--claude-dir=PATH` or the `CLAUDE_DOCKER_CONFIG_DIR` env var. This supports users who maintain multiple Claude profiles (e.g. one for API key usage, one for a Claude Enterprise subscription), each with its own config directory, OAuth token, and conversation history.

## Requirements

### Requirement: Configurable host config directory

`run.sh` SHALL read all host config items from a single base directory. The base directory defaults to `~/.claude` and MAY be overridden with `--claude-dir=PATH` (flag) or `CLAUDE_DOCKER_CONFIG_DIR` (env var). When both are provided, the flag takes precedence.

#### Scenario: Alternate config dir is used

- **GIVEN** `~/.claude-anthropic/` contains a `commands/` directory with custom slash commands
- **WHEN** user runs `claude-docker --claude-dir=~/.claude-anthropic ~/repo`
- **THEN** `/root/.claude/commands/` in the container contains the commands from `~/.claude-anthropic/commands/`

#### Scenario: Env var sets the config dir

- **GIVEN** `CLAUDE_DOCKER_CONFIG_DIR=~/.claude-anthropic` is set in the environment
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** config items are loaded from `~/.claude-anthropic/` as if `--claude-dir=~/.claude-anthropic` had been passed

### Requirement: Bind-mount host Claude config items

`run.sh` SHALL dereference and bind-mount the following host items (when present) read-only into the container at the equivalent `/root/.claude/` path: `agents/`, `skills/`, `commands/`, `CLAUDE.md`, `statusline-command.sh`. Symlinks MUST be resolved at two levels:

1. **Top-level directory symlink**: if `$CLAUDE_CONFIG_DIR/commands` is itself a symlink, `run.sh` SHALL resolve it to its real path before staging, so the copy source is always a real directory.
2. **Internal symlinks**: `run.sh` SHALL use `cp -RL` to dereference all symlinks within the directory tree during staging, so targets outside the mount root still resolve inside the container.

The stage directory MUST reside under `$HOME` (e.g. `$HOME/.cache/claude-docker/host.XXXXXX`). Colima's default mount config exposes only `$HOME` (`/Users/$USER`) to its Linux VM — `/tmp` and `$TMPDIR` are NOT shared. A bind-mount sourced from outside `$HOME` starts without error but silently yields an empty mountpoint inside the container under Colima. Docker Desktop also shares `$HOME` (under `/Users`), so `$HOME` is the one stage location that works on both runtimes.

Host `hooks/` and the `hooks` settings key are intentionally NOT carried over — host hooks exist to protect the host filesystem, which Docker already isolates.

#### Scenario: Skills via symlinks resolve in container

- **GIVEN** `~/.claude/skills/create-team` is a symlink to `~/git-work/stefanwb/claude-shared/skills/create-team`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/skills/create-team/` in the container contains the skill files (not a dangling symlink)

#### Scenario: Top-level directory symlink resolves in container

- **GIVEN** `~/.claude-anthropic/commands` is a symlink to `~/claude-config/commands`
- **WHEN** user runs `claude-docker --claude-dir=~/.claude-anthropic ~/repo`
- **THEN** `/root/.claude/commands/` in the container contains the files from `~/claude-config/commands/`

#### Scenario: Statusline renders in container

- **GIVEN** host has `~/.claude/statusline-command.sh`
- **WHEN** user runs `claude-docker` and `claude` starts
- **THEN** the statusline renders using the host-provided script

### Requirement: Container-specific settings file

When `$CLAUDE_CONFIG_DIR/settings.docker.json` exists, `run.sh` SHALL bind-mount it read-only at `/root/.claude/settings.json`. When absent, no host-derived settings file is mounted and Claude uses its built-in defaults. The regular `settings.json` is never forwarded automatically — users maintain `settings.docker.json` explicitly to prevent silent drift between host and container behaviour.

#### Scenario: Container uses dedicated settings file

- **GIVEN** `~/.claude/settings.docker.json` contains `{"effortLevel": "high"}`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/settings.json` in the container is that file

#### Scenario: Alternate config dir with settings.docker.json

- **GIVEN** `~/.claude-anthropic/settings.docker.json` exists
- **WHEN** user runs `claude-docker --claude-dir=~/.claude-anthropic ~/repo`
- **THEN** `/root/.claude/settings.json` in the container is `~/.claude-anthropic/settings.docker.json`

#### Scenario: No settings file

- **GIVEN** `settings.docker.json` does not exist in the config dir
- **WHEN** user runs `claude-docker`
- **THEN** the container starts without a host-derived `settings.json` and Claude uses defaults

### Requirement: IS_SANDBOX env for root + dangerous-skip-permissions

The image SHALL set `IS_SANDBOX=1` so `claude --dangerously-skip-permissions` (and the `--yolo` shortcut) work despite the container running as root. The container narrows blast radius compared to using the flag on the host, but is not a full sandbox — see the threat model in `claude-docker/README.md`.

#### Scenario: YOLO works in container

- **WHEN** user runs `claude-docker --yolo`
- **THEN** `claude --dangerously-skip-permissions` launches without the root refusal error
