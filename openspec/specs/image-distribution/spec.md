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

The pipeline SHALL publish the built image to a container registry when, and only when, it
runs on a version tag ref: either because the version tag was pushed, or because the pipeline
was dispatched on that tag. A push to a branch, a dispatch on a branch, or any other event,
SHALL build and scan the image without publishing it.

A version tag created by the automated release on a merge to the default branch SHALL lead to
a published image without manual steps. Such a tag is created with a token whose events start
no workflow, so the release SHALL dispatch the pipeline on the tag it created.

A run on a version tag whose reference already exists in the registry SHALL NOT publish, and
SHALL fail, whatever started it: a push of the tag, a re-run, or a dispatch. The pipeline SHALL
check the registry for the reference before publishing, and SHALL treat any outcome of that
check other than a confirmed absence as the reference being present: a registry error fails
the run rather than letting it publish. A dispatch on a tag therefore only ever fills in a
missing image, and the project's documentation SHALL say so.

The published reference SHALL be immutable: the version tag SHALL be published verbatim, and
the pipeline SHALL NOT publish a moving tag such as `latest` alongside it. A consumer
therefore names a full version tag to pull, and a given reference always denotes the same
artifact. This is guaranteed by the pipeline's refusal to publish over an existing reference,
not by convention: the build is not reproducible, since its distribution packages are not
pinned, so a rebuild of the same tag would yield a different artifact.

A version tag carrying a pre-release suffix SHALL publish on the same terms as any other:
under its own verbatim tag, through the same lint and scan gate, and without creating or
moving a stable tag. Pre-releases exist so that a candidate can be pulled and verified
against the registry before a release is committed to, and removing that path would cost
more than the ambiguity it buys back.

A published pre-release SHALL NOT carry a support promise, and the project's documentation
SHALL say so rather than leave it to be inferred from the tag's spelling. A consumer who
encounters a defect on a pre-release is directed to the latest stable tag; the fix for such
a defect is the next release, not a change published against the pre-release itself.

#### Scenario: a version tag is pushed

- **GIVEN** the build, lint and scan stages all pass
- **AND** the registry has no image under that tag
- **WHEN** a version tag is pushed
- **THEN** the image is published to the registry under that tag

#### Scenario: a merge to the default branch cuts a release

- **GIVEN** a merge to the default branch whose commits call for a new version
- **WHEN** the automated release creates the version tag
- **THEN** it dispatches the pipeline on that tag
- **AND** given the build, lint and scan stages all pass, the image is published to the
  registry under that tag

#### Scenario: a pre-release tag is pushed

- **GIVEN** the build, lint and scan stages all pass
- **AND** the registry has no image under that tag
- **WHEN** a version tag carrying a pre-release suffix is pushed
- **THEN** the image is published to the registry under that tag verbatim
- **AND** no stable tag is created or moved by that publication

#### Scenario: a branch push does not publish

- **GIVEN** a push to the default branch
- **WHEN** the pipeline runs
- **THEN** the image is built, linted and scanned
- **AND** nothing is published to the registry

#### Scenario: a dispatch on a branch does not publish

- **GIVEN** the pipeline is dispatched on a branch
- **WHEN** it runs
- **THEN** the image is built, linted and scanned
- **AND** nothing is published to the registry

#### Scenario: a run on an already-published tag is refused

- **GIVEN** an image is already published to the registry under a version tag
- **WHEN** the pipeline runs on that tag again, whether by a re-run or a dispatch
- **THEN** nothing is published to the registry
- **AND** the run fails
- **AND** the tag still denotes the artifact it was first published with

#### Scenario: a registry error during the check is refused

- **GIVEN** the pipeline runs on a version tag
- **AND** the registry check returns an error other than the reference not being found
- **WHEN** the pipeline reaches publication
- **THEN** nothing is published to the registry
- **AND** the run fails

#### Scenario: a dispatch on a tag with no image publishes it

- **GIVEN** a version tag with no image in the registry
- **AND** the build, lint and scan stages all pass
- **WHEN** the pipeline is dispatched on that tag
- **THEN** the image is published to the registry under that tag

#### Scenario: no moving tag is published

- **WHEN** a version tag is published
- **THEN** no `latest` tag and no truncated variant of the version is published beside it
- **AND** a consumer pinning the full version tag receives the same artifact on every pull

#### Scenario: the pre-release policy is documented

- **GIVEN** a pre-release published to the registry and visible to anyone browsing it
- **WHEN** a consumer reads the project's documentation for the distribution channel
- **THEN** it states that pre-release tags are published there
- **AND** it states that they are unsupported, and names the latest stable tag as what to
  use instead

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
failure at any of those stages SHALL prevent publication. A version tag whose lint or scan stage
fails therefore results in no published image.

Because a failed run is indistinguishable from an unstarted one at the registry, this
outcome — a tag that exists in the repository with no corresponding published image — SHALL be
documented rather than left to be discovered. The documentation SHALL cover both causes: a
pipeline run on the tag that failed, and an automated release whose dispatch failed, so that
no pipeline run exists for the tag; and SHALL name how to start the pipeline on the tag in the
second case.

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

#### Scenario: a release whose dispatch failed is recoverable

- **GIVEN** the automated release created a version tag
- **AND** its dispatch of the pipeline failed, so no pipeline run exists for the tag
- **WHEN** a maintainer reads the project's documentation for the distribution channel
- **THEN** it states that a tag with no pipeline run means the dispatch failed
- **AND** it names the command that dispatches the pipeline on that tag

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
