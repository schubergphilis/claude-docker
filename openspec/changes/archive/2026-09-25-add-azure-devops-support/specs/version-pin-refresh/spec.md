## MODIFIED Requirements

### Requirement: Pins stored as per-tool lockfile fragments

Resolved pins SHALL be written to one version-controlled fragment file per tool (e.g. `pins/<tool>.env`) containing sourceable shell assignments. npm-backed tools (claude-code, openspec, pnpm) SHALL record a version only, relying on npm's signed integrity, and so SHALL PyPI-backed tools (`az`, i.e. `azure-cli-core`), whose soak date is the release's first PyPI upload; binary-download tools SHALL additionally record, per published architecture, the resolved download URL paired with the sha256 of the bytes at that URL (a single URL+sha for an arch-independent artifact such as tfenv or the `azure-devops` extension wheel). Fragment files SHALL be committed to version control, not fetched at build time.

#### Scenario: npm tool fragment carries version only

- **WHEN** the refresh script resolves `pnpm`
- **THEN** `pins/pnpm.env` contains the version assignment and no URL or sha256

#### Scenario: binary tool fragment carries version, per-arch URL, and per-arch hashes

- **WHEN** the refresh script resolves `glab`
- **THEN** `pins/glab.env` contains the version and, per published architecture, the download URL and the sha256 of that URL's bytes
