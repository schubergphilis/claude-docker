## ADDED Requirements

### Requirement: Secret-manager references in forwarded credentials

When an env var that an active opt-in forwards holds a value beginning with `op://`,
`run.sh` SHALL resolve it on the host with `op read` before starting any container and
SHALL forward the resolved value in its place, by bare name (`-e NAME`) so it never
appears in argv. Under `--gh`, `GH_TOKEN` and `GITHUB_TOKEN` SHALL be resolved the same
way before they are handed to the auth-proxy sidecar. Values not beginning with `op://`
SHALL be forwarded unchanged.

If `op` is not on the host PATH, or `op read` fails, `run.sh` SHALL exit with status 1
without starting any container. Its error message SHALL name the variable and SHALL NOT
contain the reference or the resolved value.

The 1Password CLI SHALL NOT be installed in the image, and no 1Password credential SHALL
be forwarded into the container by this mechanism.

#### Scenario: Reference resolved and forwarded by name

- **GIVEN** `GITLAB_TOKEN=op://Private/GitLab/token` on the host and `op` on PATH
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `run.sh` runs `op read` for that reference on the host
- **AND** the container's `GITLAB_TOKEN` is the resolved value
- **AND** neither the reference nor the resolved value appears in the container runtime's argv

#### Scenario: op missing

- **GIVEN** `GITLAB_TOKEN=op://Private/GitLab/token` on the host and no `op` on PATH
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `run.sh` exits 1 with an error naming `GITLAB_TOKEN` and no container starts

#### Scenario: Read fails

- **GIVEN** `GITLAB_TOKEN` holds an `op://` reference that `op read` cannot resolve
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `run.sh` exits 1 with an error naming `GITLAB_TOKEN` but not the reference
- **AND** no container starts

#### Scenario: Not forwarded without the opt-in

- **GIVEN** `GITLAB_TOKEN=op://Private/GitLab/token` on the host
- **WHEN** user runs `claude-docker ~/repo` without `--glab`
- **THEN** `op` is not invoked and `GITLAB_TOKEN` does not reach the container
