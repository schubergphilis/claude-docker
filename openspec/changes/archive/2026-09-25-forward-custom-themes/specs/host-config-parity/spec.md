## ADDED Requirements

### Requirement: Forward terminal colour capability

`run.sh` SHALL forward the host's `COLORTERM` to the container alongside `TERM`, when it is set. Claude Code picks truecolor or 256-colour output from these variables; without `COLORTERM` it falls back to 256 colours in the container and renders custom theme colours rounded to the nearest palette entry, so a theme looks different from the host. When `COLORTERM` is unset on the host it SHALL stay unset in the container.

#### Scenario: Truecolor terminal renders exact theme colours

- **GIVEN** the host terminal sets `COLORTERM=truecolor`
- **WHEN** user runs `claude-docker`
- **THEN** `COLORTERM=truecolor` is set in the container
- **AND** Claude Code renders custom theme colours as 24-bit escape sequences, as it does on the host

## MODIFIED Requirements

### Requirement: Bind-mount host Claude config items

`run.sh` SHALL dereference and bind-mount the following host items (when present) read-only into the container at the equivalent `/root/.claude/` path: `agents/`, `skills/`, `commands/`, `themes/`, `CLAUDE.md`, `statusline-command.sh`. Symlinks MUST be resolved at two levels:

1. **Top-level directory symlink**: if `$CLAUDE_CONFIG_DIR/commands` is itself a symlink, `run.sh` SHALL resolve it to its real path before staging, so the copy source is always a real directory.
2. **Internal symlinks**: `run.sh` SHALL use `cp -RL` to dereference all symlinks within the directory tree during staging, so targets outside the mount root still resolve inside the container.

The stage directory MUST reside under `$HOME` (e.g. `$HOME/.cache/claude-docker/host.XXXXXX`). Colima's default mount config exposes only `$HOME` (`/Users/$USER`) to its Linux VM — `/tmp` and `$TMPDIR` are NOT shared. A bind-mount sourced from outside `$HOME` starts without error but silently yields an empty mountpoint inside the container under Colima. Docker Desktop also shares `$HOME` (under `/Users`), so `$HOME` is the one stage location that works on both runtimes.

Host `hooks/` and the `hooks` settings key are intentionally NOT carried over — host hooks exist to protect the host filesystem, which Docker already isolates.

`themes/` is mounted read-only like the other directory items, not seed-copied like `settings.json`: selecting a theme writes `settings.json`, which is already writable, while saving a theme from Claude Code's in-session theme editor writes into `themes/` and SHALL fail rather than silently diverge from the host copy. Themes are edited on the host.

#### Scenario: Skills via symlinks resolve in container

- **GIVEN** `~/.claude/skills/create-team` is a symlink to `~/repos/shared-config/skills/create-team`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/skills/create-team/` in the container contains the skill files (not a dangling symlink)

#### Scenario: Top-level directory symlink resolves in container

- **GIVEN** `~/.claude-anthropic/commands` is a symlink to `~/claude-config/commands`
- **WHEN** user runs `claude-docker --claude-dir=~/.claude-anthropic ~/repo`
- **THEN** `/root/.claude/commands/` in the container contains the files from `~/claude-config/commands/`

#### Scenario: Custom theme via symlinked themes dir resolves in container

- **GIVEN** `~/.claude/themes` is a symlink to a real directory containing `my-theme.json`
- **AND** `~/.claude/settings.docker.json` sets `"theme": "custom:my-theme"`
- **WHEN** user runs `claude-docker` and `claude` starts
- **THEN** `/root/.claude/themes/my-theme.json` in the container is a regular file with the host theme's contents
- **AND** the custom theme applies in the session

#### Scenario: Statusline renders in container

- **GIVEN** host has `~/.claude/statusline-command.sh`
- **WHEN** user runs `claude-docker` and `claude` starts
- **THEN** the statusline renders using the host-provided script
