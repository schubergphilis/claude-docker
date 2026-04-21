## ADDED Requirements

### Requirement: openspec CLI installed at a pinned version

The container image SHALL ship the `openspec` CLI (`@fission-ai/openspec`) on the default PATH. The version SHALL be held in a build ARG (`OPENSPEC_VERSION`) so pin changes are visible in diff review, consistent with the existing `CLAUDE_CODE_VERSION`, `GLAB_VERSION`, and `AWSCLI_VERSION` conventions.

#### Scenario: CLI present

- **WHEN** the container launches
- **THEN** `openspec --version` succeeds and prints the value of `OPENSPEC_VERSION` from the Dockerfile

#### Scenario: Pin is greppable in Dockerfile

- **GIVEN** a contributor wants to bump the openspec version
- **WHEN** they `grep '^ARG OPENSPEC_VERSION' claude-docker/Dockerfile`
- **THEN** exactly one line matches, giving a single edit point for the bump

### Requirement: Install uses the existing npm pattern

The `openspec` install SHALL use `npm install -g --ignore-scripts`, identical to the existing `@anthropic-ai/claude-code` install. No lifecycle scripts are executed at image build time.

#### Scenario: No postinstall side effects

- **WHEN** the image is built
- **THEN** no files are written outside `npm`'s global `node_modules` and PATH shim locations as a result of an openspec postinstall hook

### Requirement: Builds on amd64 and arm64

The Dockerfile SHALL build successfully on both `linux/amd64` and `linux/arm64`, with `openspec --version` succeeding inside the resulting image on each architecture.

#### Scenario: Builds on Apple Silicon

- **WHEN** `docker build -t claude-code:local ./claude-docker` runs on arm64
- **THEN** the build succeeds
- **AND** `docker run --rm claude-code:local openspec --version` prints the pinned version

#### Scenario: Builds on x86_64

- **WHEN** `docker build -t claude-code:local ./claude-docker` runs on amd64
- **THEN** the build succeeds
- **AND** `docker run --rm claude-code:local openspec --version` prints the pinned version

### Requirement: No credential plumbing or run.sh changes

The `openspec` CLI has no authentication or host-state requirements. Its introduction SHALL NOT add any new `run.sh` flag, bind-mount, env-var forward, or volume, and SHALL NOT alter any existing credential-handling behaviour defined by `external-cli-tools`.

#### Scenario: No new run.sh surface

- **GIVEN** the change has been applied
- **WHEN** `claude-docker --help` is invoked
- **THEN** no openspec-specific flag appears in the output
- **AND** the set of bind-mounts and forwarded env vars observed inside the container is unchanged from before the change

#### Scenario: openspec works with zero host state

- **GIVEN** the host has no `openspec` install and no `openspec`-related env vars or config files
- **WHEN** the user runs `claude-docker ~/repo` and, inside the container, `cd ~/repo && openspec --help`
- **THEN** `openspec --help` succeeds
