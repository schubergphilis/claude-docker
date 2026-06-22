## MODIFIED Requirements

### Requirement: uv binary pinned and sha256-verified

The `uv` install SHALL pin the version and verify the downloaded artifact against a sha256 per architecture before extraction. The pinned version, per-architecture download URL, and per-architecture sha256 SHALL be carried in a version-controlled lockfile fragment (`pins/uv.env`) that the Dockerfile `COPY`s and sources, rather than in hand-authored Dockerfile `ARG`s. The build SHALL download the artifact from the URL recorded in the fragment, not from a URL reconstructed inline, so the verified sha256 covers exactly that artifact. The pinned hash SHALL live in version control, not be fetched from the artifact's release URL at build time.

#### Scenario: build fails on tampered uv tarball

- **GIVEN** a build where the `uv` tarball downloaded from the fragment's recorded URL does not match the sha256 recorded in `pins/uv.env` for the build architecture
- **WHEN** the Dockerfile runs `sha256sum -c`
- **THEN** the build fails with a non-zero exit code before any extraction
- **AND** no `uv` binary is installed into `/usr/local/bin/`

#### Scenario: version, URL, and sha256 stay coupled through generation

- **WHEN** `pins/uv.env` is produced by the refresh tooling
- **THEN** the recorded version, its per-architecture download URLs, and their sha256 values correspond to the same released artifacts
- **AND** each sha256 is computed from the URL it is paired with in the fragment
- **AND** an operator never hand-computes a sha256 to bump the version
