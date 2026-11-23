## ADDED Requirements

### Requirement: In-container git identity defers to the repository's

`run.sh` SHALL forward the host's global `user.name` and `user.email` to the entrypoint, which SHALL write them to `/etc/gitconfig` before the privilege drop and unset the forwarding variables. Neither SHALL set `GIT_AUTHOR_*` or `GIT_COMMITTER_*`, so a repository's own identity, and one in the container's `~/.gitconfig`, take precedence as on the host. A failed write SHALL warn and SHALL NOT stop the entrypoint.

#### Scenario: The forwarded identity applies where nothing else is set

- **GIVEN** the host's global config sets `user.email = ada@example.com`
- **AND** the workspace repository sets no identity
- **WHEN** the agent commits in that repository
- **THEN** the commit's author and committer email are `ada@example.com`

#### Scenario: A repository's own identity wins

- **GIVEN** the host's global config sets `user.email = ada@example.com`
- **AND** the workspace repository sets `user.email = ada@work.example`
- **WHEN** the agent commits in that repository
- **THEN** the commit's author and committer email are `ada@work.example`

#### Scenario: A dangling worktree as the working directory

- **GIVEN** the session starts in a worktree whose git directory isn't in the container
- **WHEN** the entrypoint writes the identity
- **THEN** it is written, and the session starts
