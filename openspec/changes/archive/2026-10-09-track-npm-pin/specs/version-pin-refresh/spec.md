## MODIFIED Requirements

### Requirement: Pins stored as per-tool lockfile fragments

Resolved pins SHALL be written to one version-controlled fragment file per tool (e.g. `pins/<tool>.env`) containing sourceable shell assignments. npm-backed tools (npm itself, claude-code, openspec, pnpm) SHALL record a version only, relying on npm's signed integrity, and so SHALL PyPI-backed tools (`az`, i.e. `azure-cli-core`) in their fragment, whose soak date is the release's first PyPI upload; alongside `pins/az.env` the script SHALL write `pins/az-requirements.txt`, `azure-cli-core` and every transitive dependency hash-locked with `uv pip compile --universal --generate-hashes`; binary-download tools SHALL additionally record, per published architecture, the resolved download URL paired with the sha256 of the bytes at that URL (a single URL+sha for an arch-independent artifact such as tfenv or the `azure-devops` extension wheel). Fragment files SHALL be committed to version control, not fetched at build time.

#### Scenario: npm tool fragment carries version only

- **WHEN** the refresh script resolves `pnpm`
- **THEN** `pins/pnpm.env` contains the version assignment and no URL or sha256

#### Scenario: binary tool fragment carries version, per-arch URL, and per-arch hashes

- **WHEN** the refresh script resolves `glab`
- **THEN** `pins/glab.env` contains the version and, per published architecture, the download URL and the sha256 of that URL's bytes

#### Scenario: az pin writes its hash lock

- **WHEN** the refresh script writes `pins/az.env` for version V
- **THEN** it also writes `pins/az-requirements.txt` pinning `azure-cli-core==V` and every transitive dependency, each with a `--hash`

### Requirement: Build consumes fragments without hand-authored pins

The Dockerfile SHALL obtain every automated tool's version (and, for binary tools, the per-architecture download URL and sha256) by `COPY`ing and sourcing its `pins/<tool>.env` fragment, and SHALL NOT carry hand-authored version, URL, or sha256 `ARG` values for those tools. For binary tools, the build SHALL download the artifact from the URL recorded in the fragment rather than reconstructing that URL inline, so the pinned sha256 verifies the exact artifact the refresh tooling hashed and the two cannot drift apart. Each fragment SHALL be copied immediately before the build step that consumes it so that changing one tool's pin does not invalidate unrelated build layers.

#### Scenario: no inline pins for automated tools

- **WHEN** the Dockerfile is inspected
- **THEN** it contains no literal version, download URL, or sha256 value for any automated tool
- **AND** each automated tool's version/URL/sha originates from a sourced fragment

#### Scenario: npm itself is installed from its own fragment

- **WHEN** the image is built
- **THEN** the npm that replaces the one bundled with `nodejs` is installed at the version sourced from `pins/npm.env`, in its own layer before the npm-backed CLIs
- **AND** the Dockerfile carries no literal npm version

#### Scenario: build downloads from the fragment's pinned URL

- **GIVEN** a `pins/uv.env` recording a per-architecture download URL and its sha256
- **WHEN** the image is built
- **THEN** the build downloads the `uv` artifact from the URL sourced from the fragment, not from a URL reassembled in the Dockerfile
- **AND** verifies it against the sha256 paired with that URL before installing

#### Scenario: build verifies the fragment hash

- **GIVEN** a `pins/uv.env` whose recorded sha256 does not match the downloaded artifact
- **WHEN** the image is built
- **THEN** the build fails sha256 verification before installing that tool

#### Scenario: changing one pin spares unrelated layers

- **GIVEN** a build cache populated from a prior build
- **WHEN** only `pins/tfenv.env` changes and the image is rebuilt
- **THEN** the npm and npm-backed CLI install layers are served from cache and not re-run

#### Scenario: an npm bump spares the apt layer

- **GIVEN** a build cache populated from a prior build
- **WHEN** only `pins/npm.env` changes and the image is rebuilt
- **THEN** the apt layer that installs `nodejs` is served from cache and not re-run
