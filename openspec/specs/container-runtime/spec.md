# container-runtime Specification

## Purpose
TBD - created by archiving change add-container-runtime-selection. Update Purpose after archive.
## Requirements
### Requirement: Container runtime is selected, not hardcoded

`run.sh` SHALL choose the container engine at run time rather than invoking a
literal `docker`. Selection SHALL proceed as:

1. If `CLAUDE_DOCKER_RUNTIME` is set, its value is the runtime. The value SHALL
   be allowlisted to `docker` or `podman`; any other non-empty value (including
   an arbitrary binary that happens to be on PATH) SHALL cause `run.sh` to print
   an error to stderr and exit non-zero without starting a container.
2. If `CLAUDE_DOCKER_RUNTIME` is unset or empty, `run.sh` SHALL auto-detect,
   preferring `docker` and falling back to `podman`.
3. If the selected runtime is not found on PATH, `run.sh` SHALL print an error
   to stderr and exit non-zero without starting a container. When auto-detect
   finds neither engine, the error SHALL name both `docker` and `podman` and
   mention `CLAUDE_DOCKER_RUNTIME`.

The resolved runtime SHALL be invoked as `<runtime> run …` with the identical
argument list the wrapper previously passed to `docker run`.

#### Scenario: docker-first auto-detect prefers docker

- **GIVEN** `CLAUDE_DOCKER_RUNTIME` is unset
- **AND** both `docker` and `podman` are on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** the container is started via `docker run …`

#### Scenario: auto-detect falls back to podman on a podman-only host

- **GIVEN** `CLAUDE_DOCKER_RUNTIME` is unset
- **AND** `docker` is not on PATH but `podman` is
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** the container is started via `podman run …`
- **AND** no `docker: command not found` error is printed

#### Scenario: override forces podman even when docker is present

- **GIVEN** `CLAUDE_DOCKER_RUNTIME=podman`
- **AND** both `docker` and `podman` are on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** the container is started via `podman run …`

#### Scenario: invalid override is rejected before anything runs

- **GIVEN** `CLAUDE_DOCKER_RUNTIME=some-other-binary` (a value other than `docker` or `podman`)
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** `run.sh` prints an error naming the allowed values and exits non-zero
- **AND** no container is started and `some-other-binary` is never executed

#### Scenario: requested runtime missing from PATH

- **GIVEN** `CLAUDE_DOCKER_RUNTIME=podman`
- **AND** `podman` is not on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** `run.sh` prints an error that the requested runtime was not found and exits non-zero

#### Scenario: no engine installed

- **GIVEN** `CLAUDE_DOCKER_RUNTIME` is unset
- **AND** neither `docker` nor `podman` is on PATH
- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** `run.sh` prints an error naming `docker`, `podman`, and `CLAUDE_DOCKER_RUNTIME`, and exits non-zero
- **AND** no `mktemp` staging directory is left on disk

### Requirement: Runtime selection defers to the help short-circuit

Runtime selection SHALL run only after wrapper-flag parsing, so the `-h`/`--help`
short-circuit (which exits 0 before any engine is required) is never blocked by
the absence of a container runtime.

#### Scenario: --help succeeds with no engine installed

- **GIVEN** neither `docker` nor `podman` is on PATH
- **WHEN** the user runs `claude-docker --help`
- **THEN** usage text is printed to stdout and the process exits 0
- **AND** no runtime-not-found error is printed

### Requirement: Container-side paths survive MSYS/MINGW argv translation

Under an MSYS/MINGW/Cygwin shell (Git Bash on Windows), `run.sh` SHALL prevent
the shell from rewriting container-side paths in the engine argv, and SHALL
translate host bind-mount sources to a native Windows path form the engine
accepts. Container-side paths — `/workspaces/<name>`, the `-w` working
directory, `--add-dir` values, and in-container targets under `/root` and
`/run` — SHALL reach the engine verbatim. Off MSYS/MINGW/Cygwin (Linux, macOS),
no path translation SHALL be applied and the emitted argv SHALL be unchanged
from the hardcoded-`docker` behaviour.

#### Scenario: container-side paths are not rewritten under Git Bash

- **GIVEN** `run.sh` runs under Git Bash (an MSYS/MINGW shell) on Windows
- **WHEN** the wrapper builds the engine argv
- **THEN** `/workspaces/<name>`, the `-w` value, and every `--add-dir` value are passed to the engine exactly as written (not rewritten to the MSYS/Git install prefix such as `\Program Files\Git\...`)

#### Scenario: host bind-mount sources are passed in a Windows-native form

- **GIVEN** `run.sh` runs under Git Bash on Windows
- **AND** a workspace resolves to a host path such as `/c/Users/dev/repo`
- **WHEN** the wrapper builds the workspace bind-mount argument
- **THEN** the bind-mount source is expressed in a Windows-native form the engine accepts (e.g. `C:/Users/dev/repo`), so the mount resolves instead of failing with an invalid-path error

#### Scenario: non-Windows argv is unchanged

- **GIVEN** `run.sh` runs under a Linux or macOS shell (not MSYS/MINGW/Cygwin)
- **WHEN** the wrapper builds the engine argv
- **THEN** no path translation is applied and every mount/path argument is identical to the pre-change `docker run` argv

