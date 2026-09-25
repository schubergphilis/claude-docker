## MODIFIED Requirements

### Requirement: Help output enumerates every wrapper flag

The help output SHALL include a one-line description for each of the following, grouped so wrapper flags are visually distinct from the `--` passthrough contract:

- Wrapper flags: `--yolo`, `--ephemeral`, `--ro`, `--aws`, `--gh`, `--glab`, `--api`, `--az`, `--egress-allowlist`, `--iterm`, `--tmux`, `--claude-dir`, `-h`/`--help`.
- The `--` separator and its passthrough semantics for `claude` flags.
- Positional workspace arguments and the default-to-`$PWD` behaviour.
- The `CLAUDE_DOCKER_TMUX` environment variable and its accepted values (`1`, `cc`).
- The `CLAUDE_DOCKER_CONFIG_DIR` environment variable and its relationship to `--claude-dir`.
- The `CLAUDE_DOCKER_API_CA` environment variable and its relationship to `--api`.
- The `CLAUDE_DOCKER_EGRESS_ALLOW` environment variable and the entry forms it accepts.
- A brief note that `settings.docker.json` is mounted as `settings.json` in the container.

#### Scenario: All wrapper flags documented

- **WHEN** user runs `claude-docker --help`
- **THEN** the output contains each of `--yolo`, `--ephemeral`, `--ro`, `--aws`, `--gh`, `--glab`, `--api`, `--az`, `--egress-allowlist`, `--iterm`, `--tmux`, `--claude-dir`, `-h`, `--help`, `--`, `CLAUDE_DOCKER_TMUX`, `CLAUDE_DOCKER_CONFIG_DIR`, `CLAUDE_DOCKER_API_CA`, `CLAUDE_DOCKER_EGRESS_ALLOW`, and `settings.docker.json`

#### Scenario: Each wrapper flag has an explanation

- **WHEN** user runs `claude-docker --help`
- **THEN** every wrapper flag listed in the output is followed on the same or next line by a human-readable description of what it does (not just the flag name)
