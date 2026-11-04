# Spec Delta

## MODIFIED Requirements

### Requirement: Help output enumerates every wrapper flag

The help output SHALL include a one-line description for each of the following, grouped so wrapper flags are visually distinct from the `--` passthrough contract:

- Wrapper flags: `--yolo`, `--ephemeral`, `--ro`, `--ro=PATH`, `--aws`, `--gh`, `--glab`, `--api`, `--egress-lock`, `--egress-allowlist`, `--az`, `--docker`, `--iterm`, `--tmux`, `--claude-dir`, `-h`/`--help`. The `--egress-lock` description SHALL state that it requires `--api` or `--api-direct` and `ANTHROPIC_BASE_URL`, locks model traffic to that endpoint and logs every connection its proxy carries. The `--egress-allowlist` description SHALL state that it requires `--egress-lock`, takes `=FILE` or `CLAUDE_DOCKER_EGRESS_ALLOWLIST`, and refuses every host except the model endpoint and the hosts in the file. The `--docker` description SHALL state that it is equivalent to host access as the user, that workspaces are mounted at their host path, that what the session creates on the engine is removed at exit, and that it cannot be combined with `--egress-lock`.
- The `--` separator and its passthrough semantics for `claude` flags.
- Positional workspace arguments and the default-to-`$PWD` behaviour.
- The `CLAUDE_DOCKER_TMUX` environment variable and its accepted values (`1`, `cc`).
- The `CLAUDE_DOCKER_CONFIG_DIR` environment variable and its relationship to `--claude-dir`.
- The `CLAUDE_DOCKER_API_CA` environment variable and its relationship to `--api`.
- The `CLAUDE_DOCKER_AZ_CA` environment variable and its relationship to `--az`.
- The `CLAUDE_DOCKER_SOCKET` environment variable and its relationship to `--docker`.
- The `CLAUDE_DOCKER_ADD_HOSTS` environment variable and its `host:ip` format.
- The `CLAUDE_DOCKER_EGRESS_ALLOWLIST` environment variable and its relationship to `--egress-allowlist`.
- The `XDG_STATE_HOME` environment variable as the location of the saved `--egress-lock` logs.
- A brief note that `settings.docker.json` is mounted as `settings.json` in the container.

#### Scenario: All wrapper flags documented

- **WHEN** user runs `claude-docker --help`
- **THEN** the output contains each of `--yolo`, `--ephemeral`, `--ro`, `--ro=PATH`, `--aws`, `--gh`, `--glab`, `--api`, `--egress-lock`, `--egress-allowlist`, `--az`, `--docker`, `--iterm`, `--tmux`, `--claude-dir`, `-h`, `--help`, `--`, `CLAUDE_DOCKER_TMUX`, `CLAUDE_DOCKER_CONFIG_DIR`, `CLAUDE_DOCKER_API_CA`, `CLAUDE_DOCKER_AZ_CA`, `CLAUDE_DOCKER_SOCKET`, `CLAUDE_DOCKER_ADD_HOSTS`, `CLAUDE_DOCKER_EGRESS_ALLOWLIST`, `XDG_STATE_HOME`, and `settings.docker.json`

#### Scenario: Each wrapper flag has an explanation

- **WHEN** user runs `claude-docker --help`
- **THEN** every wrapper flag listed in the output is followed on the same or next line by a human-readable description of what it does (not just the flag name)

#### Scenario: Allowlist flag states its dependency

- **WHEN** user runs `claude-docker --help`
- **THEN** the `--egress-allowlist` description mentions `--egress-lock`, `=FILE` and `CLAUDE_DOCKER_EGRESS_ALLOWLIST`

#### Scenario: Docker flag states its reach

- **WHEN** user runs `claude-docker --help`
- **THEN** the `--docker` description mentions host access, the host path, removal at exit and `--egress-lock`
