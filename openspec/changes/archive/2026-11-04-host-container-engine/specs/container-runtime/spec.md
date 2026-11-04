# Spec Delta

## MODIFIED Requirements

### Requirement: The entrypoint writes the vouched-for workspaces to system git config

`run.sh` SHALL pass the vouched-for container paths as `CLAUDE_DOCKER_TRUSTED_WORKSPACES`, colon-separated. As root, before the privilege drop, the entrypoint SHALL add `safe.directory = <path>` and `<path>/*` to `/etc/gitconfig` for each `/workspaces/<name>` path, and refuse any other value, `*` included, with a warning. When `CLAUDE_DOCKER_FLAGS` lists `docker`, workspaces sit at their host path and that is the path `run.sh` vouches for, so the entrypoint SHALL also accept an absolute path, still refusing `/`, a trailing `/`, `.` or `..` components, and glob characters. The image SHALL carry no `safe.directory`, and `run.sh` SHALL pass none through the environment.

#### Scenario: the system scope lists only the vouched-for workspaces

- **GIVEN** `claude-docker ~/repo`, where the host user owns `~/repo` and `~/repo/.git`
- **WHEN** the agent runs `git config --system --get-all safe.directory`
- **THEN** it prints exactly `/workspaces/repo` and `/workspaces/repo/*`

#### Scenario: a widening value is refused

- **GIVEN** `CLAUDE_DOCKER_TRUSTED_WORKSPACES` holds `*`, `/workspaces/*` or a path outside `/workspaces/<name>`
- **WHEN** the entrypoint runs
- **THEN** that value is not written and the entrypoint warns

#### Scenario: under --docker the host path is trusted

- **GIVEN** `claude-docker --docker ~/repo`, where the host user owns `~/repo` and `~/repo/.git`
- **WHEN** the agent runs `git config --system --get-all safe.directory`
- **THEN** it prints exactly `/home/<user>/repo` and `/home/<user>/repo/*`
- **AND** a `*` or a `/a/../b` in the list is still refused with a warning
