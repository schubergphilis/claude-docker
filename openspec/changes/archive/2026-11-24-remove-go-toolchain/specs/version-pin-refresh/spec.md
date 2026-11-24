## MODIFIED Requirements

### Requirement: the task pin is manual and surfaced as an operator reminder

`update_pins.py` SHALL NOT resolve, rewrite, or soak-gate the `task` (go-task)
pin: the tool installs from a signed apt repo whose Debian `Packages` index
carries no publish dates, so the soak window that governs the `pins/` fragments
cannot be evaluated for `task` from that source. `task` SHALL therefore stay
pinned in the Dockerfile (not under `pins/`) and SHALL appear in the script's
manual-pin reminder block alongside `nodejs` and the base-image digest,
reporting the pinned version against the newest version published in the apt
repo the build installs from. When the two differ, the reminder SHALL say so and
SHALL name the newest published version.

#### Scenario: reminder reports drift from the newest published version

- **GIVEN** the Dockerfile pins `TASK_VERSION=3.53.1` and the apt repo's newest
  published version is `3.54.0`
- **WHEN** the operator runs `uv run scripts/update_pins.py`
- **THEN** the manual-pin reminder block reports the pinned version, the newest
  published version, and that the two differ
- **AND** no `pins/*.env` fragment is created for `task`

#### Scenario: reminder confirms an up-to-date pin

- **GIVEN** the pinned `TASK_VERSION` is the newest version published in the apt
  repo
- **WHEN** the operator runs `uv run scripts/update_pins.py`
- **THEN** the reminder reports the pinned version and that it matches the newest
  published version

#### Scenario: refresh run never edits the task pin

- **WHEN** `update_pins.py` completes a refresh run
- **THEN** the Dockerfile is unmodified, including `ARG TASK_VERSION`

#### Scenario: prerelease and non-semver entries are ignored

- **GIVEN** the apt repo's index lists `3.53.1` alongside a non-stable entry such
  as `3.54.0-beta.1`
- **WHEN** the reminder resolves the newest published version
- **THEN** it reports `3.53.1` as the newest and does not offer the non-stable
  entry

### Requirement: the task reminder's version resolution is best-effort

Resolving the newest published `task` version SHALL be best-effort: a network,
decompression, or parse failure SHALL degrade to a reminder stating that the
newest version could not be resolved, and SHALL NOT fail the refresh run or
change the status it exits on. Decompression of the fetched index SHALL be
bounded, so an oversized payload degrades the same way rather than exhausting
memory.

This states the rule for `task` only. `nodejs` and the base-image digest are
reported from their own pins and need no network resolution of a newest version.

#### Scenario: reminder degrades gracefully without network

- **GIVEN** the apt repo is unreachable
- **WHEN** the operator runs `uv run scripts/update_pins.py`
- **THEN** the `task` reminder states that the newest published version could not
  be resolved, and still reports the pinned version
- **AND** the run continues and exits on the same status it otherwise would

#### Scenario: unparseable index does not fail the run

- **GIVEN** the apt repo returns content that is not a readable package index
- **WHEN** the operator runs `uv run scripts/update_pins.py`
- **THEN** the `task` reminder states that the newest published version could not
  be resolved
- **AND** every automated tool's pin is refreshed exactly as it otherwise would be

#### Scenario: oversized index degrades instead of exhausting memory

- **GIVEN** the fetched index decompresses to far more than a package index
  plausibly holds
- **WHEN** the reminder resolves the newest published version
- **THEN** it reports that the newest version could not be resolved
- **AND** the run does not decompress the payload in full

### Requirement: Operator report

The refresh tooling SHALL print a report describing the outcome for every tool: each updated tool's previous and new version with the new version's age, each `held` tool with the in-soak version that was withheld, and explicit reminders for every residual manual pin (the NodeSource `nodejs` version, the `task` version, and the ubuntu base-image digest). The report SHALL indicate when the base-image tag's currently-resolved digest differs from the pinned digest.

#### Scenario: report shows updates, holds, and reminders

- **WHEN** the operator runs the refresh script
- **THEN** the report lists per-tool `old → new` versions with ages
- **AND** lists any `held` tools with the withheld version and its age
- **AND** lists `nodejs`, `task`, and the base-image digest as manual
  reminders

#### Scenario: base digest drift surfaced

- **GIVEN** the ubuntu base tag now resolves to a digest different from the pinned one
- **WHEN** the operator runs the refresh script
- **THEN** the report flags the base-image digest as differing and needing review

### Requirement: Every automated pin is verified at runtime, not just at install

For every tool pinned by an automated `pins/<tool>.env` fragment, the build pipeline SHALL execute that tool inside the image it just built and SHALL require the version the tool reports to equal its pinned version. Coverage SHALL be every automated tool, not a subset: a tool that gains an automated pin SHALL become verified without any edit to the pipeline. A reported version that differs from the pin, a tool that cannot be executed, and a tool whose version cannot be read from its output SHALL each fail the pipeline before merge. Manual pins (`nodejs`, `task`, the base-image digest) are outside this requirement; they remain operator reminders.

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
