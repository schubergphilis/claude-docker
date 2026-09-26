## ADDED Requirements

### Requirement: Custom model endpoint opt-in

Claude Code endpoint configuration SHALL NOT reach the container unless the user passes `--api`. Under `--api`, `run.sh` SHALL forward each of `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_API_KEY`, `ANTHROPIC_CUSTOM_HEADERS`, `ANTHROPIC_MODEL`, `ANTHROPIC_DEFAULT_OPUS_MODEL`, `ANTHROPIC_DEFAULT_SONNET_MODEL`, `ANTHROPIC_DEFAULT_HAIKU_MODEL`, and `ANTHROPIC_SMALL_FAST_MODEL` that is set on the host, by bare name (`-e NAME`) so no value appears on the wrapper's `docker run` argv. The mode SHALL surface as an `api` entry in `CLAUDE_DOCKER_FLAGS`.

Under `--api`, when the host sets `CLAUDE_DOCKER_API_CA` to a PEM file, `run.sh` SHALL mount it read-only at `/usr/local/share/ca-certificates/claude-docker-api.crt`, and the entrypoint SHALL install it into the system trust store as root before the privilege drop. When `CLAUDE_DOCKER_API_CA` is set but does not name a file, `run.sh` SHALL exit with an error before starting a container. `CLAUDE_DOCKER_API_CA` SHALL have no effect without `--api`.

Bedrock, Vertex, and Foundry provider selection (`CLAUDE_CODE_USE_BEDROCK`, `CLAUDE_CODE_USE_VERTEX`, `CLAUDE_CODE_USE_FOUNDRY`) is out of scope for this opt-in.

#### Scenario: No flag means no endpoint config

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** neither variable is set inside the container

#### Scenario: --api forwards endpoint config by name

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** both variables carry the host values inside the container
- **AND** the `docker run` argv contains `-e ANTHROPIC_AUTH_TOKEN` but not the token value

#### Scenario: --api trusts a private gateway CA

- **GIVEN** the host sets `CLAUDE_DOCKER_API_CA` to a PEM CA certificate
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** the certificate is present in `/etc/ssl/certs/ca-certificates.crt` inside the container

#### Scenario: Missing CA file fails loudly

- **GIVEN** the host sets `CLAUDE_DOCKER_API_CA=/nonexistent.pem`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits non-zero with an error naming the path and starts no container
