# Spec Delta

## RENAMED Requirements

- FROM: `### Requirement: The network is the boundary, so the proxy log is complete`
- TO: `### Requirement: The network is the boundary`

## MODIFIED Requirements

### Requirement: The session's egress log is saved on the host

When an `--egress-lock` session whose proxy was started exits, the EXIT trap SHALL, before removing the proxy, write the proxy's access log to `<state>/claude-docker/egress/<start>-<id>.log` and a `<start>-<id>.meta` file of `key=value` lines (`start`, `end`, `user`, `host`, `workspace`, `image`, `image_id`, `proxy_image`, `proxy_image_id`, `endpoint`), where `<state>` is `$XDG_STATE_HOME` or `~/.local/state`. That directory SHALL NOT be mounted into any container. `run.sh` SHALL NOT rotate or delete saved logs. `run.sh` SHALL check the copy: when the engine's log command fails, or the proxy had been accepting connections but the engine's output lacks squid's `Accepting HTTP Socket connections` startup line, it SHALL print that the log in that file is missing or incomplete, with the reason, and SHALL NOT report it saved. The check SHALL NOT fail the teardown.

#### Scenario: Log saved

- **WHEN** an `--egress-lock` session that connected to `example.org` exits
- **THEN** a `.log` file under the state directory contains the `CONNECT example.org:443` line
- **AND** its `.meta` file contains `endpoint=` followed by the `ANTHROPIC_BASE_URL` host
- **AND** `run.sh` reports the log saved

#### Scenario: The copy fails

- **GIVEN** an `--egress-lock` session whose engine can't return the proxy's log (for example, a log driver that doesn't support reading)
- **WHEN** the session exits
- **THEN** `run.sh` prints that the log in the `.log` file is missing or incomplete, with the engine's error
- **AND** it doesn't print "egress log saved"

#### Scenario: The log driver rotated the log

- **GIVEN** an `--egress-lock` session whose engine kept only the end of the proxy's log (`max-size` in `daemon.json`)
- **WHEN** the session exits
- **THEN** `run.sh` prints that the log in the `.log` file is incomplete because squid's startup line is gone
- **AND** it doesn't print "egress log saved"

### Requirement: The network is the boundary

A client inside the agent container that ignores proxy settings SHALL NOT reach any external address, whether it dials by name or by IP. External DNS names SHALL NOT resolve inside the agent container. The agent container's only ways off its internal network SHALL be the egress proxy, which logs every connection it carries, and, when active, the auth-proxy sidecar, which forwards only to its fixed upstreams (the GitHub hosts under `--gh`, the proxied GitLab host under `--glab`, `ANTHROPIC_BASE_URL` under `--api`). A request the agent sends straight to the auth-proxy sidecar is in the sidecar's audit log, not the egress proxy's.

#### Scenario: Proxy-unaware client to a reachable host

- **WHEN** `curl --noproxy '*' https://example.org/` runs in the agent container
- **THEN** it fails

#### Scenario: Direct IP connection

- **WHEN** `curl --noproxy '*' http://1.1.1.1/` runs in the agent container
- **THEN** it fails

#### Scenario: External DNS

- **WHEN** `getent hosts example.org` runs in the agent container
- **THEN** it returns no address
