## MODIFIED Requirements

### Requirement: Go runtime code-fetch documented in the threat model

The threat model documentation SHALL note that the Go toolchain adds runtime
code-fetch primitives: module downloads from `proxy.golang.org` (checksum-
verified against `go.sum` and, for new modules, the `sum.golang.org`
transparency log) and — because `GOTOOLCHAIN` is left at its default `auto` —
the on-demand download of a *different* Go toolchain when a project's `go.mod`
requires one newer than the pinned `GO_VERSION`. The documentation SHALL state
that the image's Go pin is therefore a floor rather than a ceiling, and SHALL
name `GOTOOLCHAIN=local` as the setting that refuses the auto-download and fails
loudly instead. The bundled-tools line SHALL list `go`.

These scenarios describe what the documentation says, not where it lives; the
project is free to move the prose between files as long as a reader can still
reach it from the front door.

#### Scenario: README threat model covers the Go fetch paths

- **WHEN** a reader inspects the project's threat-model documentation
- **THEN** the runtime code-fetch bullet names `proxy.golang.org` alongside the
  npm/PyPI/HashiCorp fetch paths
- **AND** it explains that default `GOTOOLCHAIN=auto` can pull a newer toolchain
  than the pinned one, and that `GOTOOLCHAIN=local` refuses it

#### Scenario: bundled CLIs list includes the Go toolchain

- **WHEN** a reader inspects the preinstalled-tools line at the top of the
  project's front-page documentation
- **THEN** that line lists a version-pinned `go`

#### Scenario: build-time pinning claims list the Go tarball

- **WHEN** a reader inspects the sha256-verified download list, wherever the
  threat model and the pin-refresh documentation state it
- **THEN** the Go tarball appears alongside `uv`, `glab`, the AWS CLI, and the
  `tfenv` source archive
