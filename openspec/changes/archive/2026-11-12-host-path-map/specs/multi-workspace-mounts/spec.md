## ADDED Requirements

### Requirement: Host path map on request

With `--host-paths`, or `CLAUDE_DOCKER_HOST_PATHS=1`, `run.sh` SHALL pass `claude` one `--append-system-prompt` listing each workspace's container path, its absolute host path with symlinks unresolved (Windows form under Git Bash), and whether it is read-only. The text SHALL tell the agent to work only through the container paths and to give the host path when it names a file for the user. Otherwise `run.sh` SHALL add no such text.

#### Scenario: Off by default

- **WHEN** user runs `claude-docker ~/repo`
- **THEN** the `claude` command carries no `--append-system-prompt` added by `run.sh`

#### Scenario: Map lists each workspace

- **WHEN** user runs `claude-docker --host-paths ~/repo --ro=~/lib`
- **THEN** the `claude` command carries one `--append-system-prompt` naming `/workspaces/repo` with `~/repo`'s path and `/workspaces/lib` with `~/lib`'s path marked read-only

### Requirement: Host path map leaves out control characters

A workspace whose host path or container path contains a control character SHALL be left out of the map, with a one-line warning on stderr naming its container path, control characters escaped. When every workspace is left out, `run.sh` SHALL add no text.

#### Scenario: Newline in a host path

- **GIVEN** a workspace whose host path contains a newline
- **WHEN** user runs `claude-docker --host-paths` with it
- **THEN** its host path is not in the map and a warning names its container path

#### Scenario: Newline in a container path reached through a symlink

- **GIVEN** a symlink with a plain name to a directory whose name contains a newline
- **WHEN** user runs `claude-docker --host-paths` with the symlink
- **THEN** the workspace is not in the map, the prompt gains no line from the directory name, and the warning is a single line

### Requirement: Host path map keeps the user's append

`claude` uses only the last `--append-system-prompt` it is given. Under `--host-paths`, `run.sh` SHALL remove every `--append-system-prompt VALUE` and `--append-system-prompt=VALUE` from the flags after `--` and append the last value, after a blank line, to the map in the same flag. A trailing `--append-system-prompt` with no value, and every `--append-system-prompt-file`, SHALL pass through unchanged.

#### Scenario: Both spellings, repeated

- **WHEN** user runs `claude-docker --host-paths ~/repo -- --append-system-prompt "A" --append-system-prompt=B`
- **THEN** the `claude` command carries exactly one `--append-system-prompt`, whose value is the map followed by `B`

#### Scenario: File form untouched

- **WHEN** user runs `claude-docker --host-paths ~/repo -- --append-system-prompt-file p.md`
- **THEN** `--append-system-prompt-file p.md` reaches `claude` unchanged, next to the map
