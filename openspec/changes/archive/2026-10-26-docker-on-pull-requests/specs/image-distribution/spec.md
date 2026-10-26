## MODIFIED Requirements

### Requirement: The publishing pipeline does not gate merges

The publishing pipeline SHALL run on every pull request, whatever its base branch. It SHALL
build, lint and scan the image as it does on the default branch, and SHALL NOT publish from
a pull request. Its linters and scanners, and the accepted-finding rules that steer them, run
nowhere else. Without a pull-request run, a change that breaks them (for example a pin bump
that moves a bundled dependency out of a version-scoped rule) is first caught on the default
branch and on the version tag that was meant to publish.

The publishing pipeline SHALL NOT be a required status check. Its vulnerability scan reports
findings for which no upstream fix exists, which would otherwise block an unrelated
contributor's pull request with no action available to them. A red run on a pull request is
a signal to the reviewer, not a merge gate.

A pull-request run never publishes, so a newer run for the same pull request SHALL cancel
the one in progress. A run on a branch or a tag SHALL NOT be cancelled, because it may be
publishing.

An on-demand trigger SHALL remain available, so that the pipeline can be run against a branch
that has no pull request.

#### Scenario: an unrelated pull request

- **GIVEN** a pull request that does not touch the image or its scanner
  configuration
- **WHEN** its checks run
- **THEN** the publishing pipeline builds, lints and scans the image
- **AND** nothing is published to the registry
- **AND** no required check depends on it

#### Scenario: a pin bump that invalidates an accepted-finding rule

- **GIVEN** a pull request that moves a pinned tool to a version whose bundled dependency no
  longer matches a version-scoped accepted-finding rule
- **WHEN** the publishing pipeline runs on that pull request
- **THEN** its scan reports the finding on the pull request, before the change merges

#### Scenario: an unfixed upstream vulnerability

- **GIVEN** a vulnerability is disclosed against a base-image or toolchain package for which
  no fixed version exists
- **WHEN** a contributor opens an unrelated pull request
- **THEN** the publishing pipeline may fail on it
- **AND** that pull request is not blocked by it

#### Scenario: a superseded pull-request run

- **GIVEN** the publishing pipeline is running on a pull request
- **WHEN** a new commit is pushed to that pull request
- **THEN** the run in progress is cancelled and a new one starts

#### Scenario: validating a scanner-configuration change before merge

- **GIVEN** a branch changing the image or its scanner suppressions
- **WHEN** a pull request is opened for it
- **THEN** the pipeline lints and scans the branch on that pull request
- **AND** without a pull request, the pipeline can be run on demand against that branch
