# persistent-session-storage

## Purpose

Keep every Claude Code session, credential, and project record in one shared on-disk location that survives container lifecycles, so `claude --resume` (Ctrl+A "all projects") sees the complete history regardless of which workspace launched the current container.

## Requirements

### Requirement: Sessions persist across container runs

All Claude session files, credentials, and project records SHALL live in a named Docker volume that survives `--rm` container lifecycles.

#### Scenario: Sessions survive exit

- **WHEN** the user exits a Claude session and relaunches the container
- **THEN** prior session files under `/root/.claude/projects/` remain readable

### Requirement: Single shared store across workspaces

Sessions from every workspace MUST live under the same `/root/.claude/projects/` tree so `claude --resume` Ctrl+A lists them together.

#### Scenario: Cross-workspace listing

- **WHEN** the user runs `claude --resume` in any mounted workspace and presses Ctrl+A
- **THEN** sessions from every workspace used in prior runs appear in the menu

### Requirement: Ephemeral mode opts out of persistence

`run.sh` SHALL support a `--ephemeral` flag that skips the `claude-code-root` and `claude-code-home` named-volume mounts. In this mode no OAuth tokens, `gh` login, shell history, or session history persist between container runs. Intended for one-shot or untrusted-workspace sessions.

#### Scenario: --ephemeral leaves no trace

- **GIVEN** a prior run completed with session history in `claude-code-home`
- **WHEN** user runs `claude-docker --ephemeral ~/repo`
- **THEN** `/root/.claude/projects/` starts empty inside the new container
- **AND** on exit, no writes under `/root/` or `/root/.claude/` are retained in either named volume
