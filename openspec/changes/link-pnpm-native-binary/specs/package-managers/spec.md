## ADDED Requirements

### Requirement: pnpm runs its native binary, asserted at build time

pnpm 12 ships its CLI as a native binary carried in an `@pnpm/exe.linux-*` optional dependency, with `package.json#bin.pnpm` pointing at a shebang-less placeholder that the package's install script replaces. Because the image installs with `--ignore-scripts`, the build SHALL invoke that install script itself so the placeholder is replaced, and SHALL then assert that the replacement happened, failing the build if it did not.

The assertion SHALL observe the installed bin directly — that the file at pnpm's global `bin.pnpm` path is a native executable — rather than inferring health from pnpm's own version output. Running pnpm cannot answer the question: with the placeholder in place, pnpm still exits 0 and still prints its correct version to stdout, and the only signal that it is running through Node.js is written to stderr and gated on stderr being a TTY, which no build or CI probe provides.

#### Scenario: build links the native binary over the placeholder

- **GIVEN** the Dockerfile has installed `pnpm` with `npm install -g --ignore-scripts`
- **WHEN** the build invokes pnpm's install script from the globally installed package
- **THEN** the file at `$(npm root -g)/pnpm/pnpm` is the platform's native binary rather than the shipped placeholder
- **AND** `pnpm --version` runs the binary directly, with no Node.js startup hop

#### Scenario: build fails when the placeholder was not replaced

- **GIVEN** a build in which the native binary was not linked — the install script was not invoked, failed, or a future release moved it
- **WHEN** the build asserts on the contents of pnpm's global `bin.pnpm` path
- **THEN** the build fails with a non-zero exit code in the same layer as the install
- **AND** no image is produced that would run pnpm through the Node.js fallback

#### Scenario: interactive use carries no degraded-mode warning

- **GIVEN** an image built from this Dockerfile
- **WHEN** a user runs `pnpm --version` interactively, with a TTY attached to stderr
- **THEN** nothing is written to stderr
- **AND** in particular no warning that pnpm is running through Node.js because its install script was skipped

#### Scenario: no native binary is fetched at runtime

- **GIVEN** pnpm's Node.js fallback downloads the native binary from the npm registry on first use when it cannot find an installed one, caching it next to the wrapper
- **WHEN** `pnpm` runs in the built image
- **THEN** the binary linked at build time is used
- **AND** no pnpm binary is downloaded at runtime, so the image ships no unpinned, unverified pnpm executable path

## MODIFIED Requirements

### Requirement: uv and pnpm installed on default PATH

The container image SHALL ship with `uv`, `uvx`, `pnpm`, `pnpx`, `pn`, and `pnx` on the default PATH, built arch-aware for both `amd64` and `arm64`. `pn` and `pnx` are the short aliases pnpm 12 adds to its own `bin` map; they arrive with the pinned pnpm rather than being installed separately.

#### Scenario: package managers present

- **WHEN** the container launches
- **THEN** `uv --version`, `uvx --version`, and `pnpm --version` all succeed
- **AND** `which pnpx` resolves to a binary on PATH (`pnpx` is a thin alias for `pnpm dlx` with no own-version flag)
- **AND** `which pn` and `which pnx` resolve on PATH, `pn` aliasing `pnpm` and `pnx` aliasing `pnpm dlx`

#### Scenario: builds on Apple Silicon

- **WHEN** `docker build -t claude-code:local ~/claude-docker` runs on arm64
- **THEN** the build succeeds
- **AND** no package-manager binary fails with exec-format error

#### Scenario: glibc compatibility

- **WHEN** `uv --version` runs inside the container
- **THEN** the dynamic loader resolves successfully against the base image's glibc
- **AND** no `not found` or `cannot execute binary file` error occurs

### Requirement: npm-backed installs preserve --ignore-scripts

Any package installed via `npm install -g` in the image SHALL be installed with `--ignore-scripts` to prevent post-install lifecycle scripts from executing as root at build time. Adding `pnpm` to the existing npm install line SHALL NOT remove or weaken this flag.

Where a tool is unusable without its own install script, the build MAY invoke that one script by hand after the install. Such carve-outs SHALL be individually enumerated in the Dockerfile with the reason each is needed; SHALL be limited to scripts that, on Linux, only detect the platform and move files — no network access and no execution of further code; and SHALL be re-read on each version bump of the tool that owns them. Invoking a script by hand SHALL NOT be used as a substitute for the flag, and SHALL NOT extend to any package's transitive dependencies.

#### Scenario: pnpm shares the existing --ignore-scripts invocation

- **WHEN** the Dockerfile installs `pnpm` via npm
- **THEN** the install runs as part of a single `npm install -g --ignore-scripts` invocation alongside `claude-code` and `openspec`
- **AND** no separate `npm install` invocation without `--ignore-scripts` exists in the Dockerfile

#### Scenario: hand-invoked install scripts are enumerated, not a blanket exception

- **WHEN** a reader inspects the npm install layer in the Dockerfile
- **THEN** each install script the build runs by hand is named explicitly, with the reason it is required
- **AND** no lifecycle script runs for any package that is not named there, including transitive dependencies
- **AND** the comment states that each named script is re-read when its tool's pin moves

### Requirement: runtime code-fetch capability documented in threat model

The container's threat model documentation SHALL explicitly note that `npx`, `pnpm dlx` (and its `pnpx`/`pnx` aliases), `uvx`, and `tfenv install` can fetch and execute arbitrary code from public sources at runtime — npm and PyPI for the package managers, `releases.hashicorp.com` for `tfenv install` — and that under `--yolo` a prompt-injected workspace can trigger these. The documentation SHALL distinguish `uvx` (PyPI execution) and `tfenv install` (HashiCorp release-channel execution of an unpinned terraform binary, version-selected by the workspace) from `pnpm dlx` (functionally equivalent to the already-available `npx`).

#### Scenario: README threat model includes runtime-fetch bullet

- **WHEN** a reader inspects `claude-docker/README.md` § Threat model
- **THEN** the section contains a bullet covering `npx`, `pnpm dlx`, `uvx`, and `tfenv install` as runtime code-fetch primitives
- **AND** the bullet identifies `uvx` (PyPI) and `tfenv install` (HashiCorp releases) as runtime-fetch primitives whose downloaded binaries are not pinned in the image
- **AND** the bullet names `pnpx` and `pnx` as aliases of `pnpm dlx`, so a reader does not read them as separate, undocumented commands

#### Scenario: bundled CLIs list includes new tools

- **WHEN** a reader inspects the top of `claude-docker/README.md`
- **THEN** the "Bundled CLIs on the default PATH" line lists `uv`, `uvx`, `pnpm`, `pnpx`, `pn`, `pnx`, and `tfenv` alongside the existing entries
