## ADDED Requirements

### Requirement: Every automated pin is verified at runtime, not just at install

For every tool pinned by an automated `pins/<tool>.env` fragment, the build pipeline SHALL execute that tool inside the image it just built and SHALL require the version the tool reports to equal its pinned version. Coverage SHALL be every automated tool, not a subset: a tool that gains an automated pin SHALL become verified without any edit to the pipeline. A reported version that differs from the pin, a tool that cannot be executed, and a tool whose version cannot be read from its output SHALL each fail the pipeline before merge. Manual pins (`nodejs`, `task`, the Go toolchain, the base-image digest) are outside this requirement; they remain operator reminders.

This closes the gap between "the tool installed" and "the tool works": an install step exiting zero says nothing about whether the resulting executable runs or which version it is.

#### Scenario: pin bumped but image still carries the old version

- **GIVEN** an automated pin was bumped and the image's installed tool still reports the previous version
- **WHEN** the pipeline runs against the built image
- **THEN** the pipeline fails, naming the tool, the pinned version, and the reported version
- **AND** the failure surfaces in CI before merge

#### Scenario: installed but non-functional executable

- **GIVEN** a tool whose install step exited zero but whose executable errors when invoked
- **WHEN** the pipeline probes that tool for its version
- **THEN** the pipeline fails rather than treating an unreadable version as a pass

#### Scenario: coverage follows the pin set

- **GIVEN** a tool that is added to or removed from the set of automated pins
- **WHEN** the pipeline runs
- **THEN** the set of tools it verifies matches the set of automated pins
- **AND** no pipeline definition was edited to achieve that

#### Scenario: every tool reporting its pinned version passes

- **GIVEN** an image in which every automated tool reports exactly its pinned version
- **WHEN** the pipeline verifies them
- **THEN** every tool passes and the pipeline reports each tool's pinned and reported version

### Requirement: The refresh tooling owns how each tool is probed for its version

The refresh tooling SHALL expose, in a machine-readable listing covering every automated tool, that tool's pinned version together with the command used to ask the tool its version and the rule for extracting a version from that command's output. Tools do not report versions in a common format, so the extraction rule SHALL be per-tool and SHALL live alongside the tool's other pin metadata rather than in a consumer. A consumer SHALL NOT re-derive the tool set, the probe, or the extraction rule for itself.

The listing SHALL be fail-closed: if any automated tool has no pinned version, the tooling SHALL emit no partial listing and SHALL exit non-zero, so a consumer that checks the exit status cannot silently verify an empty set.

#### Scenario: listing carries the probe and the extraction rule

- **WHEN** a consumer requests the listing
- **THEN** it receives one entry per automated tool
- **AND** each entry carries the pinned version, the version-probe command, and the rule for extracting a version from that probe's output

#### Scenario: extraction rules match the tools' real output

- **GIVEN** the version output each automated tool actually produces, whose formats differ (a bare version, a name-prefixed version, a version embedded in a longer build string)
- **WHEN** each tool's extraction rule is applied to its own output
- **THEN** the rule yields exactly that tool's version
- **AND** no tool relies on another tool's rule

#### Scenario: a missing pin yields no listing at all

- **GIVEN** one automated tool whose fragment carries no version
- **WHEN** a consumer requests the listing
- **THEN** the tooling exits non-zero
- **AND** emits no partial listing, so a consumer cannot proceed with a truncated tool set
