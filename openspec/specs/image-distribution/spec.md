# image-distribution Specification

## Purpose

Make the built image available as a fetchable, immutably referenced artifact, so that using
this tool does not require reproducing a multi-hundred-megabyte build on every machine, and so
that "the image built from version X" is something that can be pulled, diffed and scanned
after the fact. Publication is gated on the same lint-and-scan pipeline the build already
passes, so a published reference carries the same assurances as a locally built one — while
the channel itself stays out of the merge path, because an unfixed upstream CVE is not
actionable by the author of an unrelated change.

## Requirements

### Requirement: The image is published on a version tag

The pipeline SHALL publish the built image to a container registry when, and only when, a
version tag is pushed. A push to a branch, or any other event, SHALL build and scan the image
without publishing it.

The published reference SHALL be immutable: the version tag SHALL be published verbatim, and
the pipeline SHALL NOT publish a moving tag such as `latest` alongside it. A consumer
therefore names a full version tag to pull, and a given reference always denotes the same
artifact.

#### Scenario: a version tag is pushed

- **GIVEN** the build, lint and scan stages all pass
- **WHEN** a version tag is pushed
- **THEN** the image is published to the registry under that tag

#### Scenario: a branch push does not publish

- **GIVEN** a push to the default branch
- **WHEN** the pipeline runs
- **THEN** the image is built, linted and scanned
- **AND** nothing is published to the registry

#### Scenario: no moving tag is published

- **WHEN** a version tag is published
- **THEN** no `latest` tag and no truncated variant of the version is published beside it
- **AND** a consumer pinning the full version tag receives the same artifact on every pull

### Requirement: The published image covers every architecture the build supports

The published artifact SHALL be a multi-architecture manifest list covering each architecture
the image build supports, so that the distribution channel does not narrow the image's reach
below what the build itself provides. A consumer on any covered architecture SHALL receive a
natively built image from the same reference, rather than one requiring emulation.

The set of published architectures SHALL be stated explicitly by the pipeline rather than
inherited from a tooling default, so that a change to that default cannot silently alter what
is published.

#### Scenario: pulling on a covered architecture

- **GIVEN** an image published under a version tag
- **WHEN** a consumer on any covered architecture pulls that reference
- **THEN** the image received is built for that architecture natively

#### Scenario: the published architecture set is explicit

- **WHEN** the publishing configuration is read
- **THEN** the architectures to publish are named there
- **AND** the published set does not change when the underlying tooling's default changes

### Requirement: Publication is gated on the lint and scan stages

The image SHALL be linted and scanned for known vulnerabilities before it is published, and a
failure at any of those stages SHALL prevent publication. A version tag whose pipeline run
fails therefore results in no published image.

Because a failed run is indistinguishable from an unstarted one at the registry, this
outcome — a tag that exists in the repository with no corresponding published image — SHALL be
documented rather than left to be discovered.

#### Scenario: a scan failure blocks the release

- **GIVEN** a version tag is pushed
- **AND** the vulnerability scan reports a finding above the threshold that is not recorded as
  accepted
- **WHEN** the pipeline runs
- **THEN** the image is not published
- **AND** the run fails

#### Scenario: the failure mode is documented

- **WHEN** a maintainer reads the project's documentation for the distribution channel
- **THEN** it states that a failing scan on a version tag publishes nothing

### Requirement: Scan coverage is stated where it is incomplete

Where the pipeline publishes an architecture that its lint and scan stages do not cover, that
gap SHALL be recorded in the pipeline configuration and in the user-facing documentation, in
terms of which architecture is scanned and which is not.

An undocumented gap is the failure this guards against: a published multi-architecture image
implies uniform scrutiny, and a consumer cannot otherwise tell that one architecture passed
the gate on behalf of another.

#### Scenario: an architecture is published without being scanned

- **GIVEN** the pipeline publishes more architectures than it scans
- **WHEN** the pipeline configuration and the project's documentation are read
- **THEN** both name which architecture the scanners cover
- **AND** both state that the remaining architectures are published without passing them

### Requirement: Accepted scanner findings are recorded and scoped

Findings that the pipeline suppresses in order to publish SHALL be recorded in version-
controlled configuration, each carrying the reason it was accepted.

A suppression SHALL be scoped by a property that remains true for as long as its reason does —
the package's type or its location within the image — and SHALL NOT be scoped by vulnerability
identifier. An identifier-scoped suppression expires silently when upstream fixes it, and
covers none of the next findings in the same unfixable component.

A suppression SHALL NOT extend beyond the component it was accepted for. In particular, a
finding accepted because it lives in a vendored dependency tree SHALL NOT also suppress the
same package where the image installs it in its own right.

#### Scenario: a finding in vendored upstream code is accepted

- **GIVEN** a vulnerability in code vendored inside a prebuilt third-party binary, which no
  change in this repository can fix
- **WHEN** the pipeline scans the image
- **THEN** the finding does not block publication
- **AND** the suppression records the reason it was accepted

#### Scenario: a suppression does not cover a fixable instance

- **GIVEN** a suppression accepted for a component this repository does not control
- **AND** the same class of finding in a component this repository does pin and control
- **WHEN** the pipeline scans the image
- **THEN** the fixable finding is still reported and still blocks publication

#### Scenario: an unrelated vulnerable package stays enforced

- **GIVEN** a vulnerable package outside every recorded suppression's scope
- **WHEN** the pipeline scans the image
- **THEN** it blocks publication

### Requirement: The publishing pipeline does not gate merges

The publishing pipeline SHALL NOT be a required status check, and SHALL NOT run on pull
requests. Its vulnerability scan reports findings for which no upstream fix exists, which
would otherwise turn an unrelated contributor's pull request red with no action available to
them; and the repository's existing pull-request pipeline already builds the image on every
pull request.

An on-demand trigger SHALL be available, so that a change to the image or to the scanner
configuration can be validated before it merges.

#### Scenario: an unrelated pull request

- **GIVEN** a pull request that does not touch the image or its scanner configuration
- **WHEN** its checks run
- **THEN** the publishing pipeline does not run
- **AND** no required check depends on it

#### Scenario: an unfixed upstream vulnerability

- **GIVEN** a vulnerability is disclosed against a base-image or toolchain package for which
  no fixed version exists
- **WHEN** a contributor opens an unrelated pull request
- **THEN** that pull request is not blocked by it

#### Scenario: validating a scanner-configuration change before merge

- **GIVEN** a branch changing the image or its scanner suppressions
- **WHEN** a maintainer wants the lint and scan result before merging
- **THEN** the pipeline can be run on demand against that branch

### Requirement: The publishing action is referenced immutably

Every third-party action the publishing pipeline invokes SHALL be referenced by commit SHA
rather than by tag or branch, and SHALL carry a version comment that resolves to that same
SHA.

A mutable reference can change under the pipeline that publishes releases. A version comment
that does not match its SHA is worse than none: it states a provenance the pipeline does not
have, and the mismatch is invisible to a reader comparing the two by eye.

#### Scenario: a mutable reference is rejected

- **WHEN** the pipeline references a third-party action by tag or branch
- **THEN** the repository's workflow audit reports it

#### Scenario: a version comment that does not match its pin is rejected

- **GIVEN** an action pinned to a commit SHA
- **AND** a trailing version comment naming a release that resolves to a different SHA
- **WHEN** the repository's workflow audit runs
- **THEN** it reports the mismatch

### Requirement: The distribution channel is documented

The project's README SHALL document the published image as an install path: the reference to
pull, the tag scheme a consumer must pin, the architectures published, which of them the
scanners cover, and how to point the wrapper at a published image instead of a locally built
one.

Building the image locally SHALL remain a supported and documented path. The published image
is an addition to it, not a replacement, and the wrapper SHALL keep defaulting to the locally
built tag.

#### Scenario: a new user chooses an install path

- **WHEN** a user reads the README's install documentation
- **THEN** both building locally and pulling the published image are presented as supported
- **AND** the pull path states the reference, the tag to pin, and the architectures covered

#### Scenario: pointing the wrapper at the published image

- **GIVEN** a published image
- **WHEN** a user wants the wrapper to run it instead of a locally built one
- **THEN** the README names the existing image override for doing so
- **AND** the wrapper's default behaviour is unchanged for users who do not set it
