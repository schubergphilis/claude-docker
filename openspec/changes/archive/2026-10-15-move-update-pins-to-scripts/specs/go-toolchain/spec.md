## MODIFIED Requirements

### Requirement: the Go pin is manual and surfaced as an operator reminder

`update_pins.py` SHALL NOT resolve, rewrite, or soak-gate the Go pin: go.dev's
release feed carries no publish dates, so the soak window that governs the
`pins/` fragments cannot be evaluated for Go from that source. Go SHALL
therefore be pinned in the Dockerfile (not under `pins/`) and SHALL appear in
the script's manual-pin reminder block alongside `nodejs` and the base-image
digest, reporting the pinned version against the newest stable release on
go.dev. Resolving the latest stable version SHALL be best-effort: a network or
parse failure SHALL degrade to a reminder that says so, and SHALL NOT fail the
refresh run.

#### Scenario: reminder reports drift from the latest stable release

- **GIVEN** the Dockerfile pins `GO_VERSION=1.26.6` and go.dev's newest stable
  release is `go1.27.0`
- **WHEN** the operator runs `uv run scripts/update_pins.py`
- **THEN** the manual-pin reminder block reports the pinned version, the latest
  stable version, and that bumping it means updating the hashes too
- **AND** no `pins/*.env` fragment is created for Go

#### Scenario: refresh run never edits the Go pin

- **WHEN** `update_pins.py` completes a refresh run
- **THEN** the Dockerfile is unmodified, including `GO_VERSION` and both
  `GO_SHA256_*` ARGs

#### Scenario: reminder degrades gracefully without network

- **GIVEN** go.dev is unreachable
- **WHEN** the operator runs `uv run scripts/update_pins.py`
- **THEN** the Go reminder states that the latest stable version could not be
  resolved
- **AND** the run continues and exits on the same status it otherwise would
