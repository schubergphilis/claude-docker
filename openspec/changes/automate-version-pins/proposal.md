## Why

Tool versions and SHA-256 hashes are hand-authored inline in the Dockerfile (`CLAUDE_CODE_VERSION`, `UV_SHA256_*`, etc.). Maintaining them by hand is error-prone (paired version+sha must move together, hashes computed manually per arch) and, because bumps are a manual chore, the pins drift stale — which is itself a supply-chain concern as much as the unvetted-version concern the pins were meant to address. The project already intends a soak ("only pin versions ≥ 5 days old") but executes it as human discipline. This change automates that policy so pins stay both *fresh* and *soaked*, without hand-computing a single hash.

## What Changes

- Add an **`update_pins.py` script** that, for each automatable tool, resolves the newest version that is already older than a configurable soak window (default 7 days), downloads the artifact(s) for **both `amd64` and `arm64`**, computes the SHA-256(s), and writes the result — for binary tools, each download URL paired with the sha256 of its bytes — to a version-controlled lockfile.
- Move tool pins out of the Dockerfile into **per-tool lockfile fragments** under `pins/` (e.g. `pins/uv.env`), one file per tool to preserve Docker layer-cache granularity. The Dockerfile **`COPY`s and sources** these fragments instead of declaring hand-edited `ARG` values. **BREAKING** for anyone building who relied on overriding pins via `--build-arg`.
- Automate pin resolution for the tools whose version dates and hashes are API-accessible: **claude-code, openspec, pnpm** (npm registry; version only — `npm install` checks the registry-advertised `dist.integrity`, not independent provenance), and **uv, glab, tfenv, aws-cli** (GitHub release / dated tag; version + per-arch download URL + sha256, with the build fetching from the recorded URL so the hash covers exactly what it downloads).
- Make the **script's report the operator interface**: show each tool's old→new version, its age, `held` when a newer version exists but is still inside the soak window, and explicit `⚠ needs your eyes` reminders for the residual manual pins.
- Leave **apt packages** (git, tmux, gh, …) floating on Ubuntu's signed archive as today. Leave the **ubuntu base-image digest** and **NodeSource `nodejs` version** as manual pins, but have `update_pins.py` surface them as reminders (and report when the base tag's current digest differs from the pinned one).
- Support **lightweight overrides**: `update_pins.py --pin <tool>=<version>` re-resolves and re-hashes a specific version (bypassing the soak) so an operator never hand-computes a SHA; no persistent "freeze" machinery in this version.

## Capabilities

### New Capabilities
- `version-pin-refresh`: the soak-aware pin resolution + lockfile generation system — the `update_pins.py` script, the soak window, per-tool lockfile fragments, the operator report, on-demand overrides, and the manual-pin reminders for residual pins.

### Modified Capabilities
- `package-managers`: the "uv binary pinned and sha256-verified" requirement changes the pin's *home* from an inline Dockerfile `ARG` to a generated, version-controlled lockfile fragment consumed at build. The hardening property (sha256-verified at build, hash committed to version control rather than fetched at build time) is preserved.

## Impact

- **New**: `claude-docker/update_pins.py` (stdlib-only Python, run via `uv`), `claude-docker/pins/*.env` (generated, committed).
- **Modified**: `claude-docker/Dockerfile` — remove the hand-authored version/sha `ARG`s for the automated tools; `COPY` + source the `pins/` fragments at the right layers. `claude-docker/README.md` — document the refresh workflow, the soak, overrides, and the residual manual pins.
- **Unchanged**: apt package installs, the base-image digest pin mechanism, NodeSource `nodejs` (still a manual version pin), and all runtime/security behavior of the container.
- **Operator workflow**: bumping a tool changes from "edit Dockerfile + hand-compute sha" to "run `update_pins.py`, review the diff, build to test, commit."
