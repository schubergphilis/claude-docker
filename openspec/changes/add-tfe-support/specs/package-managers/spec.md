## MODIFIED Requirements

### Requirement: runtime code-fetch capability documented in threat model

The container's threat model documentation SHALL explicitly note that `npx`, `pnpm dlx`, `uvx`, and `tfenv install` can fetch and execute arbitrary code from public sources at runtime — npm and PyPI for the package managers, `releases.hashicorp.com` for `tfenv install` — and that under `--yolo` a prompt-injected workspace can trigger these. The documentation SHALL distinguish `uvx` (PyPI execution) and `tfenv install` (HashiCorp release-channel execution of an unpinned terraform binary, version-selected by the workspace) from `pnpm dlx` (functionally equivalent to the already-available `npx`).

#### Scenario: README threat model includes runtime-fetch bullet

- **WHEN** a reader inspects `claude-docker/README.md` § Threat model
- **THEN** the section contains a bullet covering `npx`, `pnpm dlx`, `uvx`, and `tfenv install` as runtime code-fetch primitives
- **AND** the bullet identifies `uvx` (PyPI) and `tfenv install` (HashiCorp releases) as runtime-fetch primitives whose downloaded binaries are not pinned in the image

#### Scenario: bundled CLIs list includes new tools

- **WHEN** a reader inspects the top of `claude-docker/README.md`
- **THEN** the "Bundled CLIs on the default PATH" line lists `uv`, `uvx`, `pnpm`, `pnpx`, and `tfenv` alongside the existing entries
