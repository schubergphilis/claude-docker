## MODIFIED Requirements

### Requirement: Releases are drafted, and published by a maintainer

On every push to the default branch, a workflow SHALL keep one draft release up to date with
the next version and its notes, counted from the Conventional Commit titles of the pull
requests merged since the highest published release. It SHALL NOT publish a release or create
a tag: a release exists only once a maintainer publishes the draft. It SHALL write only to the
draft it manages.

#### Scenario: a merge updates the draft and publishes nothing

- **GIVEN** a published release `v1.1.0`
- **WHEN** a pull request titled `feat: add a flag` is merged to the default branch
- **THEN** the managed draft release carries `v1.2.0` and lists that pull request under Features
- **AND** no tag is created and no release is published

#### Scenario: a breaking change bumps the major version

- **GIVEN** a published release `v1.1.0`
- **WHEN** a pull request whose title carries `!`, or whose description carries a `BREAKING CHANGE:` footer, is merged
- **THEN** the managed draft release carries `v2.0.0`

#### Scenario: a breaking change below 1.0.0 does not draft 1.0.0

- **GIVEN** a published release `v0.4.0`
- **WHEN** a pull request whose description carries a `BREAKING CHANGE:` footer is merged
- **THEN** the managed draft release carries `v0.5.0`
- **AND** the notes list that pull request under Breaking changes

#### Scenario: only the managed draft is written

- **GIVEN** a published release and a draft release written by hand
- **WHEN** the workflow runs
- **THEN** neither of them is changed
- **AND** the workflow creates or updates only the draft that carries its marker

#### Scenario: a merged pull request that cannot be read is named in the draft

- **GIVEN** a `Merge pull request #N` commit in the range whose pull request the workflow cannot read
- **WHEN** the workflow runs
- **THEN** the pull request is listed under the title GitHub wrote into its merge commit, which gives its type and any `!` marker, whether it was merged to the default branch or inside another pull request's branch
- **AND** the draft opens with a warning naming it and the error, asking for a re-run before publishing
- **AND** the run carries the same warning
