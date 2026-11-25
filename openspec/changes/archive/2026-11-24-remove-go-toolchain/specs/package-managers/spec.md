## MODIFIED Requirements

### Requirement: runtime code-fetch capability documented in threat model

The container's threat model documentation SHALL explicitly note that `npx`, `pnpm dlx` (and its `pnpx`/`pnx`/`pn dlx` aliases), `uvx`, and `tfenv install` can fetch and execute arbitrary code from public sources at runtime — npm and PyPI for the package managers, `releases.hashicorp.com` for `tfenv install` — and that under `--yolo` a prompt-injected workspace can trigger these.

The documentation SHALL group these by whether they add a capability the image did not already have. `pnpm dlx` running an ordinary package SHALL be identified as functionally equivalent to the already-available `npx`. `uvx` (PyPI execution), `tfenv install` (HashiCorp release-channel execution of an unpinned terraform binary, version-selected by the workspace), and `pnpm dlx` naming a package manager or a runtime SHALL each be identified as a distinct capability whose downloaded binary the image does not pin.

For the last of these, the documentation SHALL state that naming a package manager or a runtime provisions that release rather than installing the npm package of the same name; that the version is selected by the caller or by a workspace field rather than pinned in the image; that pnpm resolves these through npm's trusted package-manager registries and verifies an npm-published one against npm's signature for its exact version before executing it, so provenance is checked even though the version is not pinned; and that no switch to refuse this download is documented upstream.

These scenarios describe what the documentation says, not which file says it.

#### Scenario: README threat model includes runtime-fetch bullet

- **WHEN** a reader inspects the project's threat-model documentation
- **THEN** it contains a bullet covering `npx`, `pnpm dlx`, `uvx`, and `tfenv install` as runtime code-fetch primitives
- **AND** the bullet identifies `uvx` (PyPI) and `tfenv install` (HashiCorp releases) as runtime-fetch primitives whose downloaded binaries are not pinned in the image
- **AND** the bullet names `pnpx`, `pnx`, and `pn dlx` as aliases of `pnpm dlx`, so a reader does not read them as separate, undocumented commands

#### Scenario: dlx runtime provisioning is documented as its own capability

- **GIVEN** pnpm 12 provisions a named package manager or runtime — `node`, `deno`, `bun`, `yarn`, `npm` — instead of installing the npm package that shares the name
- **WHEN** a reader inspects the runtime code-fetch bullet
- **THEN** the bullet states that `pnpm dlx`/`pnx` can fetch and execute a runtime the image does not ship or pin, with the version chosen by the caller or by a workspace field
- **AND** it is grouped with `tfenv install` rather than presented as adding nothing over `npx`
- **AND** the bullet still states that `pnpm dlx` on an ordinary package adds no capability beyond the already-available `npx`
- **AND** the bullet states that the fetch is resolved through npm's trusted package-manager registries with an npm-published release verified against npm's signature before execution

#### Scenario: persistence of provisioned runtimes is documented

- **GIVEN** `tfenv install` writes to `/opt/tfenv/versions/`, which the documentation notes does not persist across `docker run --rm`
- **WHEN** a reader compares that to pnpm's provisioning
- **THEN** the documentation states that provisioned runtimes and package managers are stored under the container's home directory — in pnpm's package-manager store and cache — which is inside the `claude-code-root` named volume
- **AND** it states that they therefore survive container exit and are reused by later sessions, unlike the `tfenv install` downloads

#### Scenario: bundled CLIs list includes new tools

- **WHEN** a reader inspects the preinstalled-CLI list at the top of the project's front-page documentation
- **THEN** the line names `uv`, `pnpm`, and `tfenv` alongside the existing entries
- **AND** alias bins that ship with those tools (`uvx`; `pnpx`, `pn`, `pnx`) are documented under the command they alias rather than enumerated in that line, which lists one entry per tool

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
- **AND** it puts the toolchain's own directory ahead of `/root/.local/bin` and
  any volume-persisted directory after every system path
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
