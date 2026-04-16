# host-config-parity

## Purpose

Make the container feel like the user's host Claude Code: same statusline, hooks, skills, agents, commands, global preferences, and select `settings.json` keys — without copying macOS-only configuration that would break inside the Linux container.

## Requirements

### Requirement: Bind-mount host Claude config items

`run.sh` SHALL dereference and bind-mount the following host items (when present) read-only into the container at the equivalent `/root/.claude/` path: `agents/`, `skills/`, `commands/`, `hooks/`, `CLAUDE.md`, `statusline-command.sh`. Symlinks in these items MUST be resolved before mounting so targets outside the mount root still work inside the container.

#### Scenario: Skills via symlinks resolve in container

- **GIVEN** `~/.claude/skills/create-team` is a symlink to `~/git-work/stefanwb/claude-shared/skills/create-team`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/skills/create-team/` in the container contains the skill files (not a dangling symlink)

#### Scenario: Statusline renders in container

- **GIVEN** host has `~/.claude/statusline-command.sh`
- **WHEN** user runs `claude-docker` and `claude` starts
- **THEN** the statusline renders using the host-provided script

### Requirement: Curated settings subset

When the host has `~/.claude/settings.json` and `jq` is available, `run.sh` SHALL generate a subset containing only: `statusLine`, `hooks`, `effortLevel`, `autoUpdatesChannel`, `voiceEnabled`, `model`. Keys with null values MUST be dropped. The subset SHALL be mounted read-only at `/root/.claude/settings.json`.

#### Scenario: macOS-only keys stripped

- **GIVEN** host `settings.json` includes `sandbox`, `env.SSL_CERT_FILE`, and `enabledPlugins`
- **WHEN** user runs `claude-docker`
- **THEN** the container's `settings.json` contains none of those keys

#### Scenario: Hooks config carried over

- **GIVEN** host `settings.json` has a `hooks.PreToolUse` entry referencing `~/.claude/hooks/block-dangerous.sh`
- **AND** host has that script at `~/.claude/hooks/block-dangerous.sh`
- **WHEN** user runs `claude-docker` and triggers a matching tool call
- **THEN** the hook fires using the mounted script

### Requirement: jq optional

`run.sh` SHALL degrade gracefully when `jq` is not installed: skip the settings subset rather than failing the launch. All other host config items MUST still be mounted.

#### Scenario: Launch succeeds without jq

- **GIVEN** `jq` is not in PATH on the host
- **WHEN** user runs `claude-docker`
- **THEN** the container starts with host agents/skills/hooks/etc. mounted but no host-derived `settings.json`
