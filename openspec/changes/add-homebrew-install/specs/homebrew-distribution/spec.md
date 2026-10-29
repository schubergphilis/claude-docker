## ADDED Requirements

### Requirement: The wrapper is installable with Homebrew

The project SHALL provide a Homebrew formula named `claude-docker` in the `schubergphilis/tap`
tap, so that `brew install schubergphilis/tap/claude-docker` installs a `claude-docker` command
without cloning the repository or building the image.

The formula SHALL install from the source archive of a stable release tag, verified by its
checksum, and SHALL install the wrapper script from that archive unchanged.

#### Scenario: installing without a clone

- **GIVEN** a machine with Homebrew and no checkout of this repository
- **WHEN** the user runs `brew install schubergphilis/tap/claude-docker`
- **THEN** `claude-docker` is on the `PATH`
- **AND** no repository clone or image build took place

#### Scenario: a tampered archive is refused

- **GIVEN** a release archive whose checksum differs from the formula's
- **WHEN** the user installs the formula
- **THEN** the install fails before anything is installed

### Requirement: A Homebrew install defaults to the image published for its version

The installed `claude-docker` command SHALL run the image
`ghcr.io/schubergphilis/claude-docker:v<version>`, where `<version>` is the formula's version,
unless `CLAUDE_DOCKER_IMAGE` is set, in which case that value SHALL be used. The wrapper
script's own default SHALL stay as it is for every other install path.

#### Scenario: the default image matches the formula

- **GIVEN** the formula at version 1.2.3 is installed
- **AND** `CLAUDE_DOCKER_IMAGE` is not set
- **WHEN** the user runs `claude-docker`
- **THEN** the session runs `ghcr.io/schubergphilis/claude-docker:v1.2.3`

#### Scenario: the user's override wins

- **GIVEN** a Homebrew install
- **AND** `CLAUDE_DOCKER_IMAGE=claude-code:local`
- **WHEN** the user runs `claude-docker`
- **THEN** the session runs `claude-code:local`

#### Scenario: a clone is unaffected

- **WHEN** a user runs `run.sh` from a checkout without setting `CLAUDE_DOCKER_IMAGE`
- **THEN** the session runs `claude-code:local`

### Requirement: The formula does not require a particular container runtime

The formula SHALL NOT depend on a container runtime formula, since the wrapper supports
several, and SHALL tell the user after install that one is required.

#### Scenario: installing alongside Docker Desktop or Podman

- **WHEN** the user installs the formula
- **THEN** no container runtime formula is installed with it
- **AND** the install output states that Docker, Colima or Podman is required

### Requirement: The formula's test runs without a container runtime

The formula's test SHALL invoke the installed command's help and check its usage line, and
SHALL pass on a machine with no container runtime.

#### Scenario: `brew test` on a bare machine

- **GIVEN** a machine with no `docker` or `podman` on the `PATH`
- **WHEN** `brew test claude-docker` runs
- **THEN** it passes

### Requirement: Only published stable releases reach the tap

On every stable release tag (`vX.Y.Z`, no pre-release suffix) whose image publish succeeded,
the project's pipeline SHALL open a pull request on the tap that moves the formula to that
release's archive and checksum. It SHALL NOT do so for a pre-release tag, or for a tag whose
image publish did not succeed. The tap SHALL be changed only by pull request.

#### Scenario: a stable release is published

- **GIVEN** a `v1.2.3` tag whose image publish succeeded
- **WHEN** the publish completes
- **THEN** a pull request on the tap moves the formula to `v1.2.3`'s archive and checksum

#### Scenario: a release candidate is published

- **GIVEN** a `v1.2.3-rc.1` tag whose image publish succeeded
- **WHEN** the publish completes
- **THEN** no pull request is opened on the tap

#### Scenario: a publish fails

- **GIVEN** a `v1.2.3` tag whose image publish failed
- **THEN** no pull request is opened on the tap
- **AND** the formula keeps pointing at the previous release

#### Scenario: a missed bump is retried by hand

- **GIVEN** a published stable tag whose tap pull request was not opened
- **WHEN** a maintainer starts the bump workflow for that tag
- **THEN** the pull request is opened
