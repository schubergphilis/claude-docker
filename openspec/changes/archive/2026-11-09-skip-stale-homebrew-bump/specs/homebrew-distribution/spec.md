## MODIFIED Requirements

### Requirement: Only published stable releases reach the formula

On every stable release tag (`vX.Y.Z`, no pre-release suffix) whose image publish succeeded,
the project's pipeline SHALL open a pull request on this repository that moves the formula to
that release's archive and checksum. It SHALL NOT do so for a pre-release tag, for a tag whose
image publish did not succeed, or for a tag older than the one the formula names. The formula
SHALL be changed only by pull request, and merging a bump SHALL NOT publish a release.
When it opens a bump, the pipeline SHALL close any open bump pull request on this repository
for an older tag. It SHALL NOT push, open or update a bump while a bump pull request on this
repository for a newer tag is open. It SHALL leave pull requests from forks alone, and SHALL
NOT hold a bump back for one.

#### Scenario: a stable release is published

- **GIVEN** a `v1.2.3` tag whose image publish succeeded
- **WHEN** the publish completes
- **THEN** a pull request on this repository moves the formula to `v1.2.3`'s archive and
  checksum
- **AND** merging it publishes no release

#### Scenario: a release candidate is published

- **GIVEN** a `v1.2.3-rc.1` tag whose image publish succeeded
- **WHEN** the publish completes
- **THEN** no formula pull request is opened

#### Scenario: a publish fails

- **GIVEN** a `v1.2.3` tag whose image publish failed
- **THEN** no formula pull request is opened
- **AND** the formula keeps pointing at the previous release

#### Scenario: a bump for an older tag

- **GIVEN** the formula names `v1.2.3`
- **WHEN** the bump runs for `v1.2.2`
- **THEN** the formula is left at `v1.2.3` and no pull request is opened

#### Scenario: a newer release supersedes an open bump

- **GIVEN** an open formula pull request for `v1.2.3`
- **WHEN** the bump for `v1.2.4` opens its pull request
- **THEN** the `v1.2.3` pull request is closed as superseded and its branch deleted

#### Scenario: an older bump runs again while a newer one is open

- **GIVEN** the formula names `v1.1.0`
- **AND** an open formula pull request for `v1.3.0`
- **WHEN** the bump runs again for `v1.2.0`
- **THEN** no `v1.2.0` branch is pushed and no pull request is opened or edited
- **AND** the `v1.3.0` pull request is the only one open

#### Scenario: a fork's pull request from a bump branch

- **GIVEN** an open pull request from a fork whose branch is named `homebrew/v1.2.3`
- **WHEN** the bump runs for `v1.2.3`
- **THEN** the bump opens its own pull request from this repository
- **AND** the fork's pull request is neither edited nor closed

#### Scenario: a fork's newer bump branch

- **GIVEN** an open pull request from a fork whose branch is named `homebrew/v1.3.0`
- **WHEN** the bump runs for `v1.2.0`
- **THEN** the bump opens its pull request for `v1.2.0`

#### Scenario: a missed bump is retried by hand

- **GIVEN** a published stable tag whose formula pull request was not opened
- **WHEN** a maintainer starts the bump workflow for that tag
- **THEN** the pull request is opened
