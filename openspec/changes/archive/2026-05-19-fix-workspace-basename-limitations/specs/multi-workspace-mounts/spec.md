## ADDED Requirements

### Requirement: Reject only basenames that break `docker -v` parsing

`run.sh` SHALL accept any workspace whose basename is non-empty and does not contain `:`. Specifically, basenames containing spaces, parentheses, `+`, `&`, `@`, `~`, `=`, or non-ASCII characters (e.g. `AI Policy`, `Project (v2)`, `2026年計画`) MUST mount successfully. `run.sh` SHALL reject only two cases with a non-zero exit and an error message naming the offending input:

1. Basenames containing `:`, because `docker -v src:dest[:opts]` uses `:` as a field separator and there is no way to escape it in short-form `-v` syntax.
2. Empty basenames, because `/workspaces/` is not a valid bind-mount target.

The error message MUST cite the actual disallowed input (`:` or empty), not a fictitious allowlist.

#### Scenario: Basename with spaces mounts successfully

- **GIVEN** a host directory at `/Users/me/AI Policy`
- **WHEN** the user runs `claude-docker "/Users/me/AI Policy"`
- **THEN** `run.sh` proceeds to `docker run` with `-v "/Users/me/AI Policy:/workspaces/AI Policy"` (a single quoted argv element)
- **AND** the container's working directory is set to `/workspaces/AI Policy`
- **AND** the agent can read and write files in that workspace

#### Scenario: Basename with parentheses and unicode mounts successfully

- **WHEN** the user runs `claude-docker "/Users/me/Project (v2)"`
- **THEN** the workspace is mounted at `/workspaces/Project (v2)` and the container starts normally

#### Scenario: Basename containing `:` is rejected

- **WHEN** the user runs `claude-docker "/Users/me/foo:bar"`
- **THEN** `run.sh` exits non-zero with an error message naming the input and identifying `:` as the disallowed character
- **AND** no container is started

#### Scenario: Empty basename is rejected

- **GIVEN** a workspace argument that resolves to an empty basename (e.g. `/`)
- **WHEN** the user runs `claude-docker /`
- **THEN** `run.sh` exits non-zero with an error message identifying the basename as empty
- **AND** no container is started
