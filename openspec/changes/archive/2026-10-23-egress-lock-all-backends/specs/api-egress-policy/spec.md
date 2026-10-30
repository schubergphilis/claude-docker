# Spec Delta

## MODIFIED Requirements

### Requirement: Claude Code's endpoint can't be moved by the workspace

Under `--egress-lock`, `run.sh` SHALL refuse an `ANTHROPIC_BASE_URL` with any character outside RFC 3986's unreserved, reserved (except `[` and `]`) and `%`. It SHALL mount Claude Code managed settings read-only at `/etc/claude-code/managed-settings.json` whose `env` sets `ANTHROPIC_BASE_URL` to the session's endpoint (under `--api`, to `http://claude-docker-api-proxy:8080`, the auth-proxy sidecar whose only upstream is that endpoint) and every `CLAUDE_CODE_USE_*` switch that selects a model backend to `0`: `CLAUDE_CODE_USE_GATEWAY`, `CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_FOUNDRY`, `CLAUDE_CODE_USE_ANTHROPIC_AWS`, `CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD`, `CLAUDE_CODE_USE_MANTLE` and `CLAUDE_CODE_USE_VERTEX` as of Claude Code 2.1.302. Sessions without `--egress-lock` SHALL NOT get this file. CI SHALL fail when the image's Claude Code knows a `CLAUDE_CODE_USE_*` switch that is neither pinned off nor listed as selecting no backend.

#### Scenario: A project setting doesn't move the model traffic

- **GIVEN** an `--egress-lock` session whose workspace `.claude/settings.json` sets `ANTHROPIC_BASE_URL` to another host, or switches on any backend (gateway, Bedrock, Foundry, Anthropic on AWS, Anthropic on Google Cloud, Mantle or Vertex) with a base URL of its own
- **WHEN** Claude Code sends a model request
- **THEN** the request goes to the session's endpoint, not to the project's host

#### Scenario: A Claude Code release adds a backend

- **GIVEN** a claude-code pin whose bundle knows a `CLAUDE_CODE_USE_*` switch that the managed settings don't pin off and that isn't listed as selecting no backend
- **WHEN** CI runs `tests/integration/managed-settings-precedence.sh` against the image
- **THEN** it fails and names the switch

#### Scenario: Under --api the pin is the sidecar

- **GIVEN** an `--api --egress-lock` session
- **WHEN** the agent reads `/etc/claude-code/managed-settings.json`
- **THEN** its `ANTHROPIC_BASE_URL` is `http://claude-docker-api-proxy:8080`, not the host's endpoint

#### Scenario: The agent can't change the managed settings

- **GIVEN** an `--egress-lock` session
- **WHEN** the agent tries to write `/etc/claude-code/managed-settings.json` or create a file in `/etc/claude-code`
- **THEN** both fail

#### Scenario: A URL that needs escaping is refused

- **GIVEN** `ANTHROPIC_BASE_URL` contains a `"`, a backslash, a quote or whitespace
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts
