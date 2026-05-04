## ADDED Requirements

### Requirement: uv and pnpm installed on default PATH

The container image SHALL ship with `uv`, `uvx`, `pnpm`, and `pnpx` on the default PATH, built arch-aware for both `amd64` and `arm64`.

#### Scenario: package managers present

- **WHEN** the container launches
- **THEN** `uv --version`, `uvx --version`, and `pnpm --version` all succeed
- **AND** `which pnpx` resolves to a binary on PATH (pnpm 10 ships `pnpx` as a thin alias for `pnpm dlx` with no own-version flag)

#### Scenario: builds on Apple Silicon

- **WHEN** `docker build -t claude-code:local ~/claude-docker` runs on arm64
- **THEN** the build succeeds
- **AND** no package-manager binary fails with exec-format error

#### Scenario: glibc compatibility

- **WHEN** `uv --version` runs inside the container
- **THEN** the dynamic loader resolves successfully against the base image's glibc
- **AND** no `not found` or `cannot execute binary file` error occurs

### Requirement: uv binary pinned and sha256-verified

The `uv` install SHALL pin the version via a Dockerfile `ARG` and verify the downloaded artifact against an `ARG`-pinned sha256 per architecture before extraction. The pinned hash SHALL live in version control, not be fetched from the artifact's release URL at build time.

#### Scenario: build fails on tampered uv tarball

- **GIVEN** a build where the `uv` tarball downloaded from the release URL does not match the pinned `UV_SHA256_X86_64` (or `UV_SHA256_AARCH64`) ARG
- **WHEN** the Dockerfile runs `sha256sum -c`
- **THEN** the build fails with a non-zero exit code before any extraction
- **AND** no `uv` binary is installed into `/usr/local/bin/`

#### Scenario: version bumps require sha256 bumps in the same commit

- **WHEN** a contributor changes `UV_VERSION` without updating the matching `UV_SHA256_*` ARGs
- **THEN** the next build fails sha256 verification
- **AND** the failure surfaces in CI before merge

### Requirement: npm-backed installs preserve --ignore-scripts

Any package installed via `npm install -g` in the image SHALL be installed with `--ignore-scripts` to prevent post-install lifecycle scripts from executing as root at build time. Adding `pnpm` to the existing npm install line SHALL NOT remove or weaken this flag.

#### Scenario: pnpm shares the existing --ignore-scripts invocation

- **WHEN** the Dockerfile installs `pnpm` via npm
- **THEN** the install runs as part of a single `npm install -g --ignore-scripts` invocation alongside `claude-code` and `openspec`
- **AND** no separate `npm install` invocation without `--ignore-scripts` exists in the Dockerfile

### Requirement: pnpm dlx works as an npx replacement

`pnpm dlx <pkg>` SHALL fetch and execute a package from the npm registry without requiring it to be installed globally, behaving equivalently to `npx <pkg>` for the purpose of running one-off tooling.

#### Scenario: pnpm dlx runs a package on first use

- **GIVEN** a fresh container with `pnpm` installed and no global packages
- **WHEN** the user runs `pnpm dlx cowsay hello`
- **THEN** pnpm fetches `cowsay` from the npm registry into a temporary store
- **AND** executes it
- **AND** the package is not added to global node_modules

### Requirement: uvx runs arbitrary PyPI tools without a project venv

`uvx <pkg>` SHALL fetch and execute a Python package from PyPI in an ephemeral environment, with no Python interpreter required to be pre-installed in the image (uv manages its own runtime fetch).

#### Scenario: uvx runs a tool on first use

- **GIVEN** a fresh container with `uv` installed and no Python interpreter on PATH
- **WHEN** the user runs `uvx ruff --version`
- **THEN** uv fetches a Python runtime and the `ruff` package
- **AND** executes the tool
- **AND** the runtime + package are cached for subsequent uvx invocations

### Requirement: runtime code-fetch capability documented in threat model

The container's threat model documentation SHALL explicitly note that `npx`, `pnpm dlx`, and `uvx` can fetch and execute arbitrary code from public registries (npm and PyPI) at runtime, and that under `--yolo` a prompt-injected workspace can trigger these. The documentation SHALL distinguish `uvx` (new PyPI execution capability) from `pnpm dlx` (functionally equivalent to the already-available `npx`, zero marginal blast radius).

#### Scenario: README threat model includes runtime-fetch bullet

- **WHEN** a reader inspects `claude-docker/README.md` § Threat model
- **THEN** the section contains a bullet covering `npx`, `pnpm dlx`, and `uvx` as runtime code-fetch primitives
- **AND** the bullet identifies `uvx` as a new PyPI execution capability not previously available in the image

#### Scenario: bundled CLIs list includes new tools

- **WHEN** a reader inspects the top of `claude-docker/README.md`
- **THEN** the "Bundled CLIs on the default PATH" line lists `uv`, `uvx`, `pnpm`, and `pnpx` alongside the existing entries
