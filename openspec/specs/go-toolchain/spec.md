# go-toolchain Specification

## Purpose

Ship exactly one version-pinned, sha256-verified Go toolchain in the image — the one preinstalled language runtime, since the Go distribution is a single self-contained tree with no per-project variant to select and `go` resolves a project's required toolchain itself (contrast `tfenv`/`uv`, which fetch per-project Terraform/Python at runtime; see `package-managers`). The pin is manual rather than soak-gated under `pins/`, because go.dev's release feed carries no publish dates — so it must stay visible via an operator reminder. PATH ordering keeps the pinned toolchain authoritative while ensuring volume-persisted `go install` output can never shadow a system binary, and the toolchain's runtime code-fetch paths are named in the threat model.

## Requirements
### Requirement: Pinned Go toolchain installed on the default PATH

The container image SHALL ship exactly one Go toolchain, installed from the
official `go.dev` release tarball into `/usr/local/go` as
[go.dev/doc/install](https://go.dev/doc/install) prescribes, with
`/usr/local/go/bin` on the default PATH. The install SHALL be arch-aware for
both `amd64` and `arm64`. The toolchain SHALL NOT come from the distribution
archive (`golang-go`), which tracks an older release and splits GOROOT across
paths the upstream layout assumes are one tree.

Unlike `terraform` (deliberately absent, fetched per-project by `tfenv`) and
Python (fetched by `uv`), the Go toolchain is baked into the image: the Go
distribution is a single self-contained tree with no per-project variant to
choose, and `go` itself resolves a project's required toolchain at build time
(see the runtime code-fetch requirement below).

#### Scenario: go present on PATH

- **WHEN** the container launches
- **THEN** `go version` succeeds without an absolute path
- **AND** the reported version equals the `GO_VERSION` pinned in the Dockerfile
- **AND** `go env GOROOT` reports `/usr/local/go`

#### Scenario: Go environment exported explicitly, not left to defaults

- **WHEN** the container launches
- **THEN** `GOROOT` is `/usr/local/go`, `GOPATH` is `/root/go`, and `GOBIN` is
  `/root/go/bin` in the process environment — not merely as `go env` defaults —
  so scripts and non-Go tooling that read the variables directly agree with the
  toolchain
- **AND** the values are exported by the image (`ENV`), so they hold for
  `docker run`, `docker exec`, and non-login shells alike
- **AND** they are spelled against a literal `/root` rather than `${HOME}`,
  which Docker does not define at build time

#### Scenario: builds on Apple Silicon

- **WHEN** `docker build -t claude-code:local ~/claude-docker` runs on arm64
- **THEN** the build succeeds
- **AND** `go version` does not fail with an exec-format error

#### Scenario: unsupported architecture fails the build loudly

- **GIVEN** a build on an architecture that is neither `amd64` nor `arm64`
- **WHEN** the Go install step runs
- **THEN** the build exits non-zero with a message naming the unsupported
  architecture
- **AND** no partial Go tree is left under `/usr/local/go`

### Requirement: Go tarball pinned by version and sha256-verified

The Go install SHALL pin the version via a Dockerfile `ARG` (`GO_VERSION`) and
verify the downloaded tarball against an `ARG`-pinned sha256 per architecture
(`GO_SHA256_AMD64`, `GO_SHA256_ARM64`) before extraction. The pinned hashes
SHALL live in version control and SHALL NOT be fetched from the release feed at
build time — the same trust model as the `uv`, `glab`, AWS CLI, and `tfenv`
installs. `docker build .` with no `--build-arg` SHALL install the committed
version.

#### Scenario: build fails on a tampered Go tarball

- **GIVEN** a build where the tarball served at the release URL does not match
  the pinned `GO_SHA256_AMD64` (or `GO_SHA256_ARM64`)
- **WHEN** the Dockerfile runs `sha256sum -c`
- **THEN** the build fails with a non-zero exit code before extraction
- **AND** no Go tree is installed under `/usr/local/go`

#### Scenario: version bumps require sha256 bumps in the same commit

- **WHEN** a contributor changes `GO_VERSION` without updating the matching
  `GO_SHA256_*` ARGs
- **THEN** the next build fails sha256 verification
- **AND** the failure surfaces in CI before merge

### Requirement: the Go pin is manual and surfaced as an operator reminder

`update_pins.py` SHALL NOT resolve, rewrite, or soak-gate the Go pin: go.dev's
release feed carries no publish dates, so the soak window that governs the
`pins/` fragments cannot be evaluated for Go from that source. Go SHALL
therefore be pinned in the Dockerfile (not under `pins/`) and SHALL appear in
the script's manual-pin reminder block alongside `nodejs` and the base-image
digest, reporting the pinned version against the newest stable release on
go.dev. Resolving the latest stable version SHALL be best-effort: a network or
parse failure SHALL degrade to a reminder that says so, and SHALL NOT fail the
refresh run.

#### Scenario: reminder reports drift from the latest stable release

- **GIVEN** the Dockerfile pins `GO_VERSION=1.26.6` and go.dev's newest stable
  release is `go1.27.0`
- **WHEN** the operator runs `uv run update_pins.py`
- **THEN** the manual-pin reminder block reports the pinned version, the latest
  stable version, and that bumping it means updating the hashes too
- **AND** no `pins/*.env` fragment is created for Go

#### Scenario: refresh run never edits the Go pin

- **WHEN** `update_pins.py` completes a refresh run
- **THEN** the Dockerfile is unmodified, including `GO_VERSION` and both
  `GO_SHA256_*` ARGs

#### Scenario: reminder degrades gracefully without network

- **GIVEN** go.dev is unreachable
- **WHEN** the operator runs `uv run update_pins.py`
- **THEN** the Go reminder states that the latest stable version could not be
  resolved
- **AND** the run continues and exits on the same status it otherwise would

### Requirement: PATH ordering keeps GOPATH binaries non-shadowing

The default PATH SHALL place `/usr/local/go/bin` ahead of every system path and
the GOPATH `bin` directory — `/root/go/bin` for the dropped-privilege user —
last, after every system path.

`go install` writes into that GOPATH `bin` directory, which sits inside the
persistent `claude-code-root` volume and is writable by the agent. It MAY be on
the default PATH for convenience, but only in last position: a binary one
session leaves there must not be able to shadow a system binary (`git`, `gh`,
`aws`, …) on a later run. `/usr/local/go/bin` precedes the system paths so the
image's pinned toolchain wins over anything installed into the volume.

The user-local prefix `/root/.local/bin` MAY precede `/usr/local/go/bin`, by the
usual convention that a tool the user installs there is meant to win. It carries
the same agent-writable, volume-persisted caveat as `/root/go/bin`; the
distinction is intent, not trust.

#### Scenario: a persisted GOPATH binary cannot shadow a system tool

- **GIVEN** a previous session left an executable named `git` in `/root/go/bin`
  in the persistent volume
- **WHEN** a new container starts and `git` is invoked
- **THEN** the system `git` runs, not the one from `/root/go/bin`

#### Scenario: go install output is runnable without an absolute path

- **WHEN** the user runs `go install <module>@<version>` and then invokes the
  installed command by name
- **THEN** the command resolves from `/root/go/bin` on PATH

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

#### Scenario: README threat model covers the Go fetch paths

- **WHEN** a reader inspects `claude-docker/README.md` § Threat model
- **THEN** the runtime code-fetch bullet names `proxy.golang.org` alongside the
  npm/PyPI/HashiCorp fetch paths
- **AND** it explains that default `GOTOOLCHAIN=auto` can pull a newer toolchain
  than the pinned one, and that `GOTOOLCHAIN=local` refuses it

#### Scenario: bundled CLIs list includes the Go toolchain

- **WHEN** a reader inspects the top of `claude-docker/README.md`
- **THEN** the preinstalled-tools line lists a version-pinned `go`

#### Scenario: build-time pinning claims list the Go tarball

- **WHEN** a reader inspects the sha256-verified download list in § Threat model
  and § Updating pinned tool versions
- **THEN** the Go tarball appears alongside `uv`, `glab`, the AWS CLI, and the
  `tfenv` source archive

