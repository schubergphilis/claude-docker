# Spec Delta

## MODIFIED Requirements

### Requirement: Sessions are isolated and cleaned up

Each `run.sh` invocation with an active sidecar SHALL create its own container network and sidecar, with names unique to the invocation (`claude-auth-<id>` / `claude-auth-proxy-<id>`). There SHALL be one sidecar per session, serving every proxied service the session enabled (`--gh`, `--glab`, `--api`), with a single session CA. Concurrent sessions SHALL NOT share networks, sidecars, CAs or token copies. On exit, `run.sh` SHALL remove the session's sidecar and network via the existing EXIT trap. The startup prune of stopped strays SHALL also sweep the legacy `claude-gh-<id>` / `claude-gh-proxy-<id>` names.

#### Scenario: Two concurrent sessions do not interfere

- **GIVEN** two simultaneous `claude-docker --gh` sessions
- **WHEN** both perform authenticated GitHub operations
- **THEN** each session's traffic transits only its own sidecar
- **AND** the two sidecars hold independent CAs (roots differ)

#### Scenario: One sidecar serves several proxied services

- **GIVEN** host tokens for GitHub and GitLab and an `--api` gateway key
- **WHEN** user runs `claude-docker --gh --glab --api ~/repo`
- **THEN** exactly one `claude-auth-proxy-<id>` container and one `claude-auth-<id>` network exist for the session
- **AND** `gh`, `glab` and Claude Code all reach their upstreams through it

#### Scenario: Teardown removes session resources

- **WHEN** a `claude-docker --gh` session exits
- **THEN** its sidecar container and session network no longer exist

#### Scenario: Legacy strays are swept

- **GIVEN** a stopped `claude-gh-proxy-<id>` container and an unused `claude-gh-<id>` network left by an older version
- **WHEN** `run.sh` starts
- **THEN** both are removed

### Requirement: Proxied requests are logged

The sidecar SHALL log every proxied request (method, host, path, response status) as structured output on its stdout. The log SHALL be retrievable via `$RUNTIME logs <sidecar>` for the lifetime of the session and is deliberately not persisted beyond it. Logs SHALL NOT contain the token or `Authorization` header values. `run.sh` SHALL print the sidecar container name at session start so the log stream is discoverable.

#### Scenario: API call appears in the audit log

- **WHEN** `gh api /user` runs inside the agent container
- **THEN** `docker logs claude-auth-proxy-<id>` shows a structured entry with host `api.github.com`, method `GET`, path `/user`, and status `200`
- **AND** no log entry contains the token

#### Scenario: Audit log is discoverable

- **WHEN** a `claude-docker --gh` session starts with an active sidecar
- **THEN** `run.sh` prints the sidecar container name before the agent session begins
- **AND** `$RUNTIME logs <printed name>` succeeds
