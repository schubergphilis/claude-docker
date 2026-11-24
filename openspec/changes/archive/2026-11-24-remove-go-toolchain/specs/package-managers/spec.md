## ADDED Requirements

### Requirement: Go is not preinstalled and a child-image recipe is documented

The container image SHALL NOT ship a Go toolchain, nor export `GOROOT`,
`GOPATH` or `GOBIN`. A project's language runtimes are fetched per project or go
in a child image (`docs/vision-and-scope.md`). The usage documentation SHALL
show a child-image recipe that installs Go, as the worked example of the
`CLAUDE_DOCKER_IMAGE` pattern, and SHALL note that a child image's package
managers add to the runtime code-fetch surface.

#### Scenario: no go in the base image

- **WHEN** the container launches from the base image
- **THEN** `go` is not on PATH
- **AND** `/usr/local/go` does not exist
- **AND** `GOROOT`, `GOPATH` and `GOBIN` are unset

#### Scenario: usage docs show a Go child image

- **WHEN** a reader opens the *Extending the image* section of `docs/usage.md`
- **THEN** it contains a child-image `Dockerfile` that installs a pinned,
  sha256-verified Go toolchain
- **AND** it names the supply-chain pinning as the child image's responsibility

### Requirement: PATH ordering keeps volume-persisted directories non-shadowing

The default PATH SHALL place `/root/.local/bin` (the `pip install --user` /
`uv tool install` prefix) after every system path. The directory lives in the
persistent `claude-code-root` volume and is agent-writable, so a binary one
session leaves there MUST NOT shadow a system binary (`git`, `gh`, `aws`, …) on
a later run.

#### Scenario: a persisted user-prefix binary cannot shadow a system tool

- **GIVEN** a previous session left an executable named `gh` in
  `/root/.local/bin` in the persistent volume
- **WHEN** a new container starts, in any workspace, and `gh` is invoked
- **THEN** the system `gh` runs, not the one from `/root/.local/bin`

#### Scenario: user-prefix installs are runnable without an absolute path

- **WHEN** the user installs a tool whose entry point lands in
  `/root/.local/bin` (for example `uv tool install` or `pip install --user`)
  and then invokes it by name
- **THEN** the command resolves from `/root/.local/bin` on PATH, provided no
  system binary of that name exists

#### Scenario: the smoke suite enforces the ordering

- **WHEN** `tests/smoke/smoke.sh` runs against a built image
- **THEN** the in-container assertions confirm that `/usr/bin` precedes
  `/root/.local/bin` and that `git` resolves to `/usr/bin/git`
