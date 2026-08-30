# package-managers

## Purpose

Provide `uv`/`uvx` (Python) and `pnpm`/`pnpx` (Node) inside the container for general-purpose user-tier work, with the same pin-and-verify hardening as other binary tools where the ecosystem supports it. Project-specific language runtimes (rust, ruby, etc.) are deliberately excluded — they belong in child images via the `CLAUDE_DOCKER_IMAGE` extension pattern. Go is the one exception, shipped in the image under its own `go-toolchain` capability: the Go distribution is a single self-contained tree with no per-project variant to select, and `go` resolves a project's required toolchain itself.

## Requirements

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

The `uv` install SHALL pin the version and verify the downloaded artifact against a sha256 per architecture before extraction. The pinned version, per-architecture download URL, and per-architecture sha256 SHALL be carried in a version-controlled lockfile fragment (`pins/uv.env`) that the Dockerfile `COPY`s and sources, rather than in hand-authored Dockerfile `ARG`s. The build SHALL download the artifact from the URL recorded in the fragment, not from a URL reconstructed inline, so the verified sha256 covers exactly that artifact. The pinned hash SHALL live in version control, not be fetched from the artifact's release URL at build time.

#### Scenario: build fails on tampered uv tarball

- **GIVEN** a build where the `uv` tarball downloaded from the fragment's recorded URL does not match the sha256 recorded in `pins/uv.env` for the build architecture
- **WHEN** the Dockerfile runs `sha256sum -c`
- **THEN** the build fails with a non-zero exit code before any extraction
- **AND** no `uv` binary is installed into `/usr/local/bin/`

#### Scenario: version bumps require sha256 bumps in the same commit

- **WHEN** a contributor hand-edits `pins/uv.env`, changing `UV_VERSION` without
  updating the matching `UV_SHA256_*` values
- **THEN** the next build fails sha256 verification
- **AND** the failure surfaces in CI before merge

#### Scenario: version, URL, and sha256 stay coupled through generation

- **WHEN** `pins/uv.env` is produced by the refresh tooling
- **THEN** the recorded version, its per-architecture download URLs, and their sha256 values correspond to the same released artifacts
- **AND** each sha256 is computed from the URL it is paired with in the fragment
- **AND** an operator never hand-computes a sha256 to bump the version

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

The container's threat model documentation SHALL explicitly note that `npx`, `pnpm dlx`, `uvx`, and `tfenv install` can fetch and execute arbitrary code from public sources at runtime — npm and PyPI for the package managers, `releases.hashicorp.com` for `tfenv install` — and that under `--yolo` a prompt-injected workspace can trigger these. The documentation SHALL distinguish `uvx` (PyPI execution) and `tfenv install` (HashiCorp release-channel execution of an unpinned terraform binary, version-selected by the workspace) from `pnpm dlx` (functionally equivalent to the already-available `npx`).

#### Scenario: README threat model includes runtime-fetch bullet

- **WHEN** a reader inspects `claude-docker/README.md` § Threat model
- **THEN** the section contains a bullet covering `npx`, `pnpm dlx`, `uvx`, and `tfenv install` as runtime code-fetch primitives
- **AND** the bullet identifies `uvx` (PyPI) and `tfenv install` (HashiCorp releases) as runtime-fetch primitives whose downloaded binaries are not pinned in the image

#### Scenario: bundled CLIs list includes new tools

- **WHEN** a reader inspects the top of `claude-docker/README.md`
- **THEN** the "Bundled CLIs on the default PATH" line lists `uv`, `uvx`, `pnpm`, `pnpx`, and `tfenv` alongside the existing entries

### Requirement: Private registry passthrough via --registry

`run.sh` SHALL provide a `--registry` opt-in flag that surfaces the host's
native `uv`, `npm`/`pnpm`, and pip-based (`pip`/`pipenv`) private-registry
configuration into the container using the package managers' own discovery
mechanisms, rather than any wrapper-specific configuration. When `--registry`
is NOT passed, no registry configuration and no registry credentials SHALL
reach the container, and the package managers SHALL fall back to their built-in
public defaults (the npm registry and PyPI). The flag SHALL compose with all
other flags and SHALL NOT require `--aws`.

This requirement governs registry *configuration* only. The image SHALL NOT be
required to ship `pip`, `pipenv`, or a Python runtime for this requirement to be
met; the forwarded pip configuration applies to whatever pip executes inside the
container (e.g. via `uvx pipenv` or a child image).

When `--registry` is set, `run.sh`:

- SHALL mount read-only, and only when present on the host (a missing file is a
  silent no-op), each of: the host npm config (`~/.npmrc`, or the file named by
  `npm_config_userconfig` / `NPM_CONFIG_USERCONFIG` when set) at `/root/.npmrc`,
  `~/.config/uv/uv.toml` at `/root/.config/uv/uv.toml`, and the
  platform-appropriate pip config — `~/.config/pip/pip.conf` on Linux or
  `~/Library/Application Support/pip/pip.conf` on macOS — at
  `/root/.config/pip/pip.conf`.
- SHALL NOT mount `~/.netrc`. Because netrc is a machine-keyed store that
  commonly holds credentials for hosts unrelated to the package registry,
  forwarding the whole file into a full-egress container is too broad; netrc-
  based registry auth is intentionally not supported by this flag (registry
  auth belongs in npmrc/pip.conf, the index URL, or `UV_INDEX_*_PASSWORD`).
- SHALL forward, only when set on the host, the native env vars
  `npm_config_registry`, `NPM_CONFIG_REGISTRY`, `NODE_AUTH_TOKEN`, `NPM_TOKEN`,
  `UV_INDEX_URL`, `UV_DEFAULT_INDEX`, `UV_EXTRA_INDEX_URL`, `UV_INDEX`,
  `UV_KEYRING_PROVIDER`, `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`,
  `PIP_TRUSTED_HOST`, and `PIPENV_PYPI_MIRROR`. It SHALL NOT forward `UV_NETRC`
  (it points uv at a netrc file that is no longer mounted).
- SHALL additionally forward every set host environment variable whose name
  matches `UV_INDEX_*_USERNAME` or `UV_INDEX_*_PASSWORD`, so uv's per-index
  credential variables (whose names derive from a user-chosen index name) reach
  the container without being individually enumerated, while other `UV_*`
  variables are NOT blanket-forwarded.
- SHALL append `registry` to the statusline opt-in tag list.

All mounted config files SHALL be read-only, so the container cannot mutate host
registry credentials and a `--registry` session cannot persist registry
credential state into the `claude-code-root` volume.

Resolution policy SHALL be whatever the host configuration expresses: the
wrapper imposes none of its own. Setting a default registry/index in the host
config natively replaces the public default (confining resolution to the
configured feed), and re-admitting public registries is expressed in the host's
own native config.

#### Scenario: no flag means no registry config reaches the container

- **GIVEN** the host has a `~/.npmrc` with a private `registry=` line and exports `UV_DEFAULT_INDEX`
- **WHEN** the user runs `claude-docker ~/repo` without `--registry`
- **THEN** `/root/.npmrc` inside the container does not contain the host's private registry config
- **AND** `echo $UV_DEFAULT_INDEX` inside the container is empty
- **AND** `pnpm config get registry` returns the public npm default

#### Scenario: --registry mounts host npmrc read-only

- **GIVEN** the host has a `~/.npmrc` configuring a private registry with an auth token
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** `/root/.npmrc` inside the container contains the host file's contents
- **AND** `pnpm config get registry` returns the private registry URL
- **AND** a write to `/root/.npmrc` from inside the container fails with EROFS

#### Scenario: --registry mounts host pip config and forwards PIP_* env

- **GIVEN** the host has a pip config (at its platform-appropriate user location) setting a private `index-url`, and exports `PIP_INDEX_URL`
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** `/root/.config/pip/pip.conf` inside the container contains the host pip config
- **AND** `echo $PIP_INDEX_URL` inside the container prints the host value
- **AND** a pip-based install (e.g. via `uvx pipenv`) resolves against the private index
- **AND** without `--registry`, `/root/.config/pip/pip.conf` is absent and `echo $PIP_INDEX_URL` is empty

#### Scenario: --registry forwards uv index env vars including dynamic credential vars

- **GIVEN** the host exports `UV_DEFAULT_INDEX=https://example.test/simple/`, `UV_INDEX_INTERNAL_USERNAME=aws`, and `UV_INDEX_INTERNAL_PASSWORD=tok`
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** all three variables are present in the container environment
- **AND** other unrelated `UV_*` host variables (e.g. `UV_CACHE_DIR`) are not forwarded

#### Scenario: --registry is silent when no host registry config exists

- **GIVEN** the host has no `~/.npmrc`, no `~/.netrc`, no `~/.config/uv/uv.toml`, and none of the forwarded env vars set
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** the container starts without error
- **AND** the package managers fall back to their public defaults

#### Scenario: statusline tag reflects the opt-in

- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** the statusline `docker:` prefix includes `registry` in the opt-in tag list

