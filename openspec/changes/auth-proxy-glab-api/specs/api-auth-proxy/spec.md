# Spec Delta

## Purpose

Keep the `--api` gateway credential (`ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN`) out of the agent container by having Claude Code talk to the per-session auth proxy sidecar, which adds the real credential and forwards to the configured model endpoint.

## ADDED Requirements

### Requirement: Gateway credential is isolated from the agent container

Under `--api`, the host values of `ANTHROPIC_API_KEY` and `ANTHROPIC_AUTH_TOKEN` SHALL be given only to the sidecar's environment. For each of the two the host set to a non-empty value, the agent container SHALL get that variable set to the placeholder `claude-docker-proxy`. A variable the host left unset or empty SHALL stay unset in the agent container.

#### Scenario: Key not visible inside the agent container

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal` and `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** `echo $ANTHROPIC_AUTH_TOKEN` inside the agent container prints `claude-docker-proxy`
- **AND** `ANTHROPIC_API_KEY` is unset inside the agent container
- **AND** `tok` appears nowhere in `/proc/1/environ` or the environment of any process inside the agent container

### Requirement: Model traffic is routed through the sidecar

Under `--api`, the agent container's `ANTHROPIC_BASE_URL` SHALL point at the sidecar over the session-private network, not at the host value. The sidecar SHALL forward each request to the host's `ANTHROPIC_BASE_URL`, or `https://api.anthropic.com` when unset. It SHALL keep any path prefix of that URL and set the upstream `Host` to the upstream's host. Streaming (`text/event-stream`) responses SHALL be passed through without buffering.

#### Scenario: Claude Code works through a gateway with a path prefix

- **GIVEN** the host exports `ANTHROPIC_BASE_URL=https://llm.internal/anthropic` and `ANTHROPIC_API_KEY=key`
- **WHEN** Claude Code sends `POST /v1/messages` with `stream: true` from the agent container
- **THEN** the gateway receives `POST /anthropic/v1/messages` with `Host: llm.internal` and `x-api-key: key`
- **AND** the streamed events reach Claude Code incrementally

#### Scenario: Default upstream

- **GIVEN** the host exports `ANTHROPIC_API_KEY=key` and no `ANTHROPIC_BASE_URL`
- **WHEN** Claude Code sends a request from the agent container
- **THEN** the sidecar forwards it to `https://api.anthropic.com`

### Requirement: Gateway credential headers are replaced or dropped

The sidecar SHALL replace a client `x-api-key` with the host `ANTHROPIC_API_KEY`, and a client `Authorization` with `Bearer <host ANTHROPIC_AUTH_TOKEN>`. When the host did not provide the matching variable, the sidecar SHALL remove that header rather than forward it. That way neither a placeholder nor a claude.ai OAuth token from the persisted volume can reach the upstream.

#### Scenario: Placeholder replaced

- **GIVEN** the host exports `ANTHROPIC_AUTH_TOKEN=tok`
- **WHEN** a request with `Authorization: Bearer claude-docker-proxy` passes through the sidecar
- **THEN** the upstream receives `Authorization: Bearer tok`

#### Scenario: Unprovided credential is stripped

- **GIVEN** the host exports only `ANTHROPIC_API_KEY=key`
- **WHEN** a request carrying both `x-api-key: claude-docker-proxy` and `Authorization: Bearer <oauth-token>` passes through the sidecar
- **THEN** the upstream receives `x-api-key: key` and no `Authorization` header

### Requirement: Gateway CA is trusted by the sidecar

When `CLAUDE_DOCKER_API_CA` names a PEM file under `--api`, the sidecar SHALL trust it for its upstream connection, alongside the public roots it already trusts. Certificate verification of the upstream SHALL stay on. The existing install of that CA into the agent container's trust store SHALL be unchanged.

#### Scenario: Private-CA gateway

- **GIVEN** `ANTHROPIC_BASE_URL=https://llm.internal`, whose certificate chains to the CA in `CLAUDE_DOCKER_API_CA`
- **WHEN** Claude Code sends a request from the agent container
- **THEN** the sidecar's upstream TLS handshake succeeds with verification enabled

#### Scenario: Public-CA gateway still works with a CA set

- **GIVEN** `CLAUDE_DOCKER_API_CA` names a corporate root and `ANTHROPIC_BASE_URL` uses a publicly trusted certificate
- **WHEN** Claude Code sends a request from the agent container
- **THEN** the upstream handshake succeeds

### Requirement: Model endpoint proxy fails closed

The existing `--api` check (exit 1 when neither credential is set) SHALL still run first. If the sidecar then fails to start or is not ready within the startup timeout, `run.sh` SHALL tear down the session resources and exit with an error. It SHALL NOT fall back to forwarding the credential.

#### Scenario: Sidecar failure is fatal

- **GIVEN** the host exports `ANTHROPIC_API_KEY=key` and the sidecar image cannot be pulled
- **WHEN** user runs `claude-docker --api ~/repo`
- **THEN** `run.sh` exits non-zero naming the sidecar failure and `--api-direct`
- **AND** the key was never forwarded into any container

### Requirement: Model endpoint requests are logged

Every request the sidecar proxies to the model endpoint SHALL be logged in the session's sidecar audit log (method, path, status). The log SHALL NOT contain the credential, request or response bodies, or any `x-api-key` / `Authorization` value.

#### Scenario: Request appears in the audit log without secrets

- **WHEN** Claude Code sends `POST /v1/messages` through the sidecar
- **THEN** `$RUNTIME logs claude-auth-proxy-<id>` shows an entry with method `POST`, path `/v1/messages` and the status
- **AND** no entry contains the key or prompt content
