## ADDED Requirements

### Requirement: Help flag prints usage and exits

`run.sh` SHALL recognise `-h` and `--help` as wrapper flags. When either appears in the argument list before the `--` separator, `run.sh` MUST print usage to stdout and exit 0 without starting a Docker container and without creating the host-config staging directory.

#### Scenario: --help alone

- **WHEN** user runs `claude-docker --help`
- **THEN** usage text is printed to stdout and the process exits 0 with no `docker run` invocation

#### Scenario: -h alone

- **WHEN** user runs `claude-docker -h`
- **THEN** usage text is printed to stdout and the process exits 0 with no `docker run` invocation

#### Scenario: --help mixed with other wrapper flags

- **WHEN** user runs `claude-docker --aws --gh --help ~/repo`
- **THEN** usage text is printed to stdout and the process exits 0 with no `docker run` invocation and no `mktemp` staging directory left on disk

### Requirement: Help output enumerates every wrapper flag

The help output SHALL include a one-line description for each of the following, grouped so wrapper flags are visually distinct from the `--` passthrough contract:

- Wrapper flags: `--yolo`, `--ephemeral`, `--ro`, `--aws`, `--gh`, `--glab`, `--iterm`, `--tmux`, `--claude-dir`, `-h`/`--help`.
- The `--` separator and its passthrough semantics for `claude` flags.
- Positional workspace arguments and the default-to-`$PWD` behaviour.
- The `CLAUDE_DOCKER_TMUX` environment variable and its accepted values (`1`, `cc`).
- The `CLAUDE_DOCKER_CONFIG_DIR` environment variable and its relationship to `--claude-dir`.
- A brief note that `settings.docker.json` is mounted as `settings.json` in the container.

#### Scenario: All wrapper flags documented

- **WHEN** user runs `claude-docker --help`
- **THEN** the output contains each of `--yolo`, `--ephemeral`, `--ro`, `--aws`, `--gh`, `--glab`, `--iterm`, `--tmux`, `--claude-dir`, `-h`, `--help`, `--`, `CLAUDE_DOCKER_TMUX`, `CLAUDE_DOCKER_CONFIG_DIR`, and `settings.docker.json`

#### Scenario: Each wrapper flag has an explanation

- **WHEN** user runs `claude-docker --help`
- **THEN** every wrapper flag listed in the output is followed on the same or next line by a human-readable description of what it does (not just the flag name)

### Requirement: Flags after `--` are not intercepted

The `--` separator contract SHALL take precedence over help detection. Any occurrence of `-h` or `--help` after `--` MUST be forwarded verbatim to the `claude` binary inside the container.

#### Scenario: --help after separator passes through

- **WHEN** user runs `claude-docker -- --help`
- **THEN** `run.sh` launches the container and invokes `claude --help`, and does NOT print `run.sh`'s own usage text

#### Scenario: -h after separator passes through

- **WHEN** user runs `claude-docker ~/repo -- -h`
- **THEN** `run.sh` launches the container and invokes `claude -h`

### Requirement: Help invocation has no side effects

When help is printed, `run.sh` SHALL NOT default an empty workspace list to `$PWD`, create a staging directory via `mktemp`, copy host Claude config, or invoke Docker. The only observable effect MUST be the stdout write and a zero exit status.

#### Scenario: No staging dir created

- **WHEN** user runs `claude-docker --help`
- **THEN** no `host.*` directory is left under `$HOME/.cache/claude-docker/` after the command returns

#### Scenario: No docker process spawned

- **WHEN** user runs `claude-docker --help` on a host with no `docker` binary on PATH
- **THEN** the command still succeeds with exit 0
