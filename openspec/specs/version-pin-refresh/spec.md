# version-pin-refresh Specification

## Purpose

Keep the image's pinned tool versions current without hand-editing hashes, and keep the pins that *cannot* be automated visible. `update_pins.py` refreshes the soak-gated `pins/*.env` fragments; the pins it cannot soak-gate — because their upstream release source publishes no dates — stay in the Dockerfile and surface instead as an operator reminder that reports the pinned version against the newest published one. `task` (go-task) is such a pin: it installs from a signed apt repo whose Debian `Packages` index carries no publish dates, the same reason `go` stays manual (see `go-toolchain`). Reminder resolution is best-effort by design, so a network or parse failure never changes what a refresh run does to the automated pins.

## Requirements

### Requirement: Soak-aware version resolution

The refresh tooling SHALL, for each automated tool, select the highest stable released version whose publish date is older than a configurable soak window (default 7 days). Prerelease versions SHALL be excluded. By default, selection SHALL include major-version increments (e.g. 10.x → 11.x); the tooling SHALL NOT restrict resolution to the currently-pinned major line. An operator MAY pass `--block-major-bumps` to constrain a run to the currently-pinned major; when set and the newest soaked version crosses the major, the tooling SHALL instead select the newest soaked version within the current major and SHALL report the crossed major as blocked. A newer version that exists but falls inside the soak window SHALL NOT be selected; the current pin SHALL be retained instead.

#### Scenario: major version increment is selected and flagged

- **GIVEN** tool X is pinned at 10.33.2 and version 11.5.3 was published 9 days ago with a soak window of 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the resolved pin for X is 11.5.3
- **AND** the report marks the change as a major bump, visually distinct from minor/patch updates

#### Scenario: major bump suppressed under --block-major-bumps

- **GIVEN** tool X is pinned at 10.33.2, version 10.34.1 was published 15 days ago, and version 11.5.3 was published 9 days ago, with a soak window of 7 days
- **WHEN** the operator runs the refresh script with `--block-major-bumps`
- **THEN** the resolved pin for X is 10.34.1
- **AND** the report shows 11.5.3 as available but blocked by `--block-major-bumps`

#### Scenario: newest soaked version selected

- **GIVEN** tool X has versions 1.2.0 (published 20 days ago) and 1.3.0 (published 10 days ago) and the soak window is 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the resolved pin for X is 1.3.0

#### Scenario: too-new version held back by the soak

- **GIVEN** tool X is pinned at 1.3.0 and a version 1.4.0 was published 3 days ago with a soak window of 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the pin for X remains 1.3.0
- **AND** the report marks X as `held`, naming the in-soak version and its age

#### Scenario: no newer version available

- **GIVEN** the pinned version is already the newest released version
- **WHEN** the operator runs the refresh script
- **THEN** the pin is unchanged and the report shows no update for that tool

### Requirement: Hashes generated for both architectures

For every binary-download tool (uv, glab, tfenv, aws-cli), the refresh tooling SHALL download the resolved artifact for both `amd64` and `arm64` regardless of the host architecture and record the computed sha256 for each architecture the tool publishes. Alongside each sha256, the tooling SHALL record the resolved download URL the bytes were fetched from, so the recorded hash and the URL it covers stay coupled in the fragment. A tool that fails to provide an expected architecture's artifact SHALL cause the refresh to fail rather than record a partial pin.

#### Scenario: both arch hashes recorded

- **WHEN** the refresh script resolves a new `uv` version
- **THEN** the resulting fragment contains a sha256 for both `x86_64` and `aarch64`
- **AND** each hash matches the sha256 of the artifact actually published for that architecture
- **AND** the fragment records, next to each sha256, the download URL that hash was computed from

#### Scenario: missing architecture fails loudly

- **GIVEN** a resolved version that is missing its `arm64` artifact
- **WHEN** the refresh script attempts to hash both architectures
- **THEN** the script exits non-zero
- **AND** no fragment is written with a single-architecture hash

### Requirement: Pins stored as per-tool lockfile fragments

Resolved pins SHALL be written to one version-controlled fragment file per tool (e.g. `pins/<tool>.env`) containing sourceable shell assignments. npm-backed tools (claude-code, openspec, pnpm) SHALL record a version only, relying on npm's signed integrity; binary-download tools SHALL additionally record, per published architecture, the resolved download URL paired with the sha256 of the bytes at that URL (a single URL+sha for an arch-independent artifact such as tfenv). Fragment files SHALL be committed to version control, not fetched at build time.

#### Scenario: npm tool fragment carries version only

- **WHEN** the refresh script resolves `pnpm`
- **THEN** `pins/pnpm.env` contains the version assignment and no URL or sha256

#### Scenario: binary tool fragment carries version, per-arch URL, and per-arch hashes

- **WHEN** the refresh script resolves `glab`
- **THEN** `pins/glab.env` contains the version and, per published architecture, the download URL and the sha256 of that URL's bytes

### Requirement: Build consumes fragments without hand-authored pins

The Dockerfile SHALL obtain every automated tool's version (and, for binary tools, the per-architecture download URL and sha256) by `COPY`ing and sourcing its `pins/<tool>.env` fragment, and SHALL NOT carry hand-authored version, URL, or sha256 `ARG` values for those tools. For binary tools, the build SHALL download the artifact from the URL recorded in the fragment rather than reconstructing that URL inline, so the pinned sha256 verifies the exact artifact the refresh tooling hashed and the two cannot drift apart. Each fragment SHALL be copied immediately before the build step that consumes it so that changing one tool's pin does not invalidate unrelated build layers.

#### Scenario: no inline pins for automated tools

- **WHEN** the Dockerfile is inspected
- **THEN** it contains no literal version, download URL, or sha256 value for any automated tool
- **AND** each automated tool's version/URL/sha originates from a sourced fragment

#### Scenario: build downloads from the fragment's pinned URL

- **GIVEN** a `pins/uv.env` recording a per-architecture download URL and its sha256
- **WHEN** the image is built
- **THEN** the build downloads the `uv` artifact from the URL sourced from the fragment, not from a URL reassembled in the Dockerfile
- **AND** verifies it against the sha256 paired with that URL before installing

#### Scenario: build verifies the fragment hash

- **GIVEN** a `pins/uv.env` whose recorded sha256 does not match the downloaded artifact
- **WHEN** the image is built
- **THEN** the build fails sha256 verification before installing that tool

#### Scenario: changing one pin spares unrelated layers

- **GIVEN** a build cache populated from a prior build
- **WHEN** only `pins/tfenv.env` changes and the image is rebuilt
- **THEN** the npm install layer is served from cache and not re-run

### Requirement: Operator report

The refresh tooling SHALL print a report describing the outcome for every tool: each updated tool's previous and new version with the new version's age, each `held` tool with the in-soak version that was withheld, and explicit reminders for every residual manual pin (the NodeSource `nodejs` version, the `task` version, the Go toolchain version, and the ubuntu base-image digest). The report SHALL indicate when the base-image tag's currently-resolved digest differs from the pinned digest.

#### Scenario: report shows updates, holds, and reminders

- **WHEN** the operator runs the refresh script
- **THEN** the report lists per-tool `old → new` versions with ages
- **AND** lists any `held` tools with the withheld version and its age
- **AND** lists `nodejs`, `task`, `go`, and the base-image digest as manual
  reminders

#### Scenario: base digest drift surfaced

- **GIVEN** the ubuntu base tag now resolves to a digest different from the pinned one
- **WHEN** the operator runs the refresh script
- **THEN** the report flags the base-image digest as differing and needing review

### Requirement: On-demand version override without hand-hashing

The refresh tooling SHALL support resolving and hashing a specific operator-chosen version of a tool, bypassing the soak window, so that an operator never hand-computes a sha256. The report SHALL mark a tool resolved this way as an explicit override rather than a soaked selection.

#### Scenario: override re-hashes a chosen version

- **WHEN** the operator requests a specific version of `uv` via the override flag
- **THEN** the script downloads and hashes that version for both architectures
- **AND** writes `pins/uv.env` with that version and its computed hashes
- **AND** the report marks `uv` as an override

### Requirement: Failed refresh leaves pins intact

If resolution, download, or hashing fails for any tool, the refresh tooling SHALL exit non-zero and SHALL NOT leave a partially written or half-updated set of fragments.

#### Scenario: network failure does not corrupt pins

- **GIVEN** a transient failure fetching one tool's release metadata
- **WHEN** the operator runs the refresh script
- **THEN** the script exits non-zero
- **AND** the existing committed fragments are unchanged

### Requirement: Unchanged pins are re-verified, not rewritten

When a tool's resolved version equals its committed pin, the refresh tooling SHALL NOT recompute and overwrite the committed sha256(s). For a tool with hashed artifacts it SHALL instead re-download each committed artifact URL and compare against the committed sha256; on mismatch — the artifact was re-published with different bytes at the pinned version — it SHALL fail loudly and leave the committed pin unchanged, rather than silently re-pin to the new bytes. A download failure during this check SHALL NOT abort the run, since an unchanged tool has no work to do.

#### Scenario: re-published artifact at a pinned version fails loudly

- **GIVEN** a tool whose resolved version equals the committed pin
- **AND** the artifact at the committed URL now hashes differently than the committed sha256
- **WHEN** the operator runs the refresh script
- **THEN** the script exits non-zero, reporting an integrity mismatch
- **AND** the committed pin is left unchanged

#### Scenario: unchanged, still-matching pin is not rewritten

- **GIVEN** a tool whose resolved version equals the committed pin
- **AND** the artifact still matches the committed sha256
- **WHEN** the operator runs the refresh script
- **THEN** the committed fragment is left unchanged (not rewritten)

### Requirement: Refresh tooling has no third-party runtime dependencies

The refresh tooling SHALL run using only its language's standard library and ubiquitous system tooling already required by the build — it SHALL NOT require installing third-party packages from a language registry (PyPI, npm, etc.) to execute. This keeps the trusted base of a supply-chain tool minimal; adding a runtime dependency SHALL be a deliberate, reviewable change.

#### Scenario: runs without installing third-party packages

- **WHEN** an operator runs the refresh tooling on a machine with only the pinned interpreter and the build's existing system tools
- **THEN** it executes successfully without fetching or installing any third-party package
- **AND** its declared dependency set is empty

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
both together, and SHALL be derived from the same base-image line whose digest
the run reports as pinned. For the same reason, the version SHALL be read only
from index entries for the `task` package itself: another package published into
the repo is not a version `apt-get install task=<v>` can resolve.

#### Scenario: only the task package's versions are considered

- **GIVEN** the apt repo's index lists `task` at `3.53.1` and a second package at
  a higher version
- **WHEN** the reminder resolves the newest published version
- **THEN** it reports `3.53.1`

#### Scenario: suite follows a base-image bump

- **GIVEN** the pinned base image is `ubuntu:resolute-<date>@sha256:<digest>`
- **WHEN** the reminder resolves the newest published `task` version
- **THEN** it queries the apt repo's `resolute` suite
- **AND** bumping the pinned base image to a different release moves the queried
  suite with it, with no separate edit

### Requirement: the task reminder's version resolution is best-effort

Resolving the newest published `task` version SHALL be best-effort: a network,
decompression, or parse failure SHALL degrade to a reminder stating that the
newest version could not be resolved, and SHALL NOT fail the refresh run or
change the status it exits on. Decompression of the fetched index SHALL be
bounded, so an oversized payload degrades the same way rather than exhausting
memory.

This states the rule for `task` only. Each manual pin's reminder carries the same
best-effort contract inside its own capability's requirement — Go's in
`go-toolchain` — so the rule has exactly one owner per pin and the two cannot
drift apart.

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

#### Scenario: oversized index degrades instead of exhausting memory

- **GIVEN** the fetched index decompresses to far more than a package index
  plausibly holds
- **WHEN** the reminder resolves the newest published version
- **THEN** it reports that the newest version could not be resolved
- **AND** the run does not decompress the payload in full
