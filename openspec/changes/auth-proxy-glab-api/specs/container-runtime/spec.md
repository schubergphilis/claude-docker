# Spec Delta

## MODIFIED Requirements

### Requirement: Static host entries for networks without DNS

`run.sh` SHALL read `CLAUDE_DOCKER_ADD_HOSTS` from the host environment as a comma-separated list of `host:ip` entries and pass each to the runtime as `--add-host host:ip` on the agent container, so the entries land in the container's `/etc/hosts`. When the auth-proxy sidecar is started, `run.sh` SHALL pass the same entries to the sidecar too, so it can reach its upstreams.

- An entry SHALL match a hostname (letters, digits, `.` and `-`), a `:`, and an IPv4 or IPv6 address (hex digits, `.` and `:`). Any other entry SHALL make `run.sh` exit 1 with an error naming the entry, before starting any container. Unset or empty adds nothing.
- Entries for a hostname the sidecar intercepts (case-insensitive) SHALL NOT be passed to the agent container, which must keep resolving it to the sidecar: `github.com`, `api.github.com` and `uploads.github.com` while the `--gh` site is active, the proxied GitLab host (without its port) while the `--glab` site is active, and `claude-docker-api-proxy` while the `--api` site is active. `run.sh` SHALL print a one-line warning for each skipped entry. The sidecar still receives them.
- The variable SHALL NOT be forwarded into any container.

#### Scenario: Entries reach the agent container

- **GIVEN** the host exports `CLAUDE_DOCKER_ADD_HOSTS=gitlab.example.com:10.1.2.3,devops.example.com:10.1.2.4`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `getent hosts gitlab.example.com` inside the container prints `10.1.2.3`
- **AND** `getent hosts devops.example.com` inside the container prints `10.1.2.4`

#### Scenario: A malformed entry fails loudly

- **GIVEN** the host exports `CLAUDE_DOCKER_ADD_HOSTS=gitlab.example.com`
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `run.sh` exits 1 with an error naming `gitlab.example.com` and starts no container

#### Scenario: The --gh sidecar keeps its hosts

- **GIVEN** the host exports `CLAUDE_DOCKER_ADD_HOSTS=github.com:140.82.121.4`
- **WHEN** user runs `claude-docker --gh ~/repo` and the sidecar starts
- **THEN** the sidecar container resolves `github.com` to `140.82.121.4`
- **AND** the agent container resolves `github.com` to the sidecar
- **AND** stderr carries a warning naming the skipped entry

#### Scenario: The --glab sidecar keeps the GitLab host

- **GIVEN** the host exports `CLAUDE_DOCKER_ADD_HOSTS=gitlab.example.com:10.1.2.3` and a GitLab token for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/repo` and the sidecar starts
- **THEN** the sidecar container resolves `gitlab.example.com` to `10.1.2.3`
- **AND** the agent container resolves `gitlab.example.com` to the sidecar
- **AND** stderr carries a warning naming the skipped entry
