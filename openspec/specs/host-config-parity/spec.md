# host-config-parity

## Purpose

Make the container feel like the user's host Claude Code: same statusline, skills, agents, commands, global preferences, and a container-specific `settings.docker.json` when the user provides one — without copying macOS-only configuration or host-filesystem hooks that would misfire inside the Linux container.

## Requirements

### Requirement: Bind-mount host Claude config items

`run.sh` SHALL dereference and bind-mount the following host items (when present) read-only into the container at the equivalent `/root/.claude/` path: `agents/`, `skills/`, `commands/`, `CLAUDE.md`, `statusline-command.sh`. Symlinks in these items MUST be resolved before mounting so targets outside the mount root still work inside the container. Host `hooks/` and the `hooks` settings key are intentionally NOT carried over — host hooks exist to protect the host filesystem, which Docker already isolates.

#### Scenario: Skills via symlinks resolve in container

- **GIVEN** `~/.claude/skills/create-team` is a symlink to `~/git-work/stefanwb/claude-shared/skills/create-team`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/skills/create-team/` in the container contains the skill files (not a dangling symlink)

#### Scenario: Statusline renders in container

- **GIVEN** host has `~/.claude/statusline-command.sh`
- **WHEN** user runs `claude-docker` and `claude` starts
- **THEN** the statusline renders using the host-provided script

### Requirement: Container-specific settings file

When `~/.claude/settings.docker.json` exists on the host, `run.sh` SHALL bind-mount it read-only at `/root/.claude/settings.json`. When absent, no host-derived settings file is mounted and Claude uses its built-in defaults. The host's own `~/.claude/settings.json` is NOT derived from or filtered into the container — the user maintains `settings.docker.json` explicitly to avoid surprising drift.

#### Scenario: Container uses dedicated settings file

- **GIVEN** `~/.claude/settings.docker.json` contains `{"effortLevel": "high"}`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/settings.json` in the container is that file

#### Scenario: No settings file

- **GIVEN** `~/.claude/settings.docker.json` does not exist
- **WHEN** user runs `claude-docker`
- **THEN** the container starts without a host-derived `settings.json` and Claude uses defaults

### Requirement: IS_SANDBOX env for root + dangerous-skip-permissions

The image SHALL set `IS_SANDBOX=1` so `claude --dangerously-skip-permissions` (and the `--yolo` shortcut) work despite the container running as root. The Docker container is the sandbox; this is strictly safer than using the flag on the host.

#### Scenario: YOLO works in container

- **WHEN** user runs `claude-docker --yolo`
- **THEN** `claude --dangerously-skip-permissions` launches without the root refusal error
