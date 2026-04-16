## ADDED Requirements

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
