## ADDED Requirements

### Requirement: the task pin is manual and surfaced as an operator reminder

`update_pins.py` SHALL NOT resolve, rewrite, or soak-gate the `task` (go-task)
pin: the tool installs from a signed apt repo whose Debian `Packages` index
carries no publish dates, so the soak window that governs the `pins/` fragments
cannot be evaluated for `task` from that source. `task` SHALL therefore stay
pinned in the Dockerfile (not under `pins/`) and SHALL appear in the script's
manual-pin reminder block alongside `nodejs`, `go`, and the base-image digest,
reporting the pinned version against the newest version published in the apt
repo the build installs from. When the two differ, the reminder SHALL say so and
SHALL name the newest published version.

#### Scenario: reminder reports drift from the newest published version

- **GIVEN** the Dockerfile pins `TASK_VERSION=3.53.1` and the apt repo's newest
  published version is `3.54.0`
- **WHEN** the operator runs `uv run update_pins.py`
- **THEN** the manual-pin reminder block reports the pinned version, the newest
  published version, and that the two differ
- **AND** no `pins/*.env` fragment is created for `task`

#### Scenario: reminder confirms an up-to-date pin

- **GIVEN** the pinned `TASK_VERSION` is the newest version published in the apt
  repo
- **WHEN** the operator runs `uv run update_pins.py`
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

### Requirement: the task reminder queries the suite the build installs from

The newest published `task` version SHALL be resolved from the same apt suite
the image's build installs from, so the reminder cannot report a version that
the build's own `apt-get install` would not find. The suite SHALL be derived
from the pinned base image rather than hard-coded, so a base-image bump moves
both together.

#### Scenario: suite follows a base-image bump

- **GIVEN** the pinned base image is `ubuntu:resolute-<date>@sha256:<digest>`
- **WHEN** the reminder resolves the newest published `task` version
- **THEN** it queries the apt repo's `resolute` suite
- **AND** bumping the pinned base image to a different release moves the queried
  suite with it, with no separate edit

### Requirement: manual-pin reminder resolution is best-effort

Resolving the newest published version for a manual pin SHALL be best-effort: a
network, decompression, or parse failure SHALL degrade to a reminder stating that
the newest version could not be resolved, and SHALL NOT fail the refresh run or
change the status it exits on.

#### Scenario: reminder degrades gracefully without network

- **GIVEN** the apt repo is unreachable
- **WHEN** the operator runs `uv run update_pins.py`
- **THEN** the `task` reminder states that the newest published version could not
  be resolved, and still reports the pinned version
- **AND** the run continues and exits on the same status it otherwise would

#### Scenario: unparseable index does not fail the run

- **GIVEN** the apt repo returns content that is not a readable package index
- **WHEN** the operator runs `uv run update_pins.py`
- **THEN** the `task` reminder states that the newest published version could not
  be resolved
- **AND** every automated tool's pin is refreshed exactly as it otherwise would be
