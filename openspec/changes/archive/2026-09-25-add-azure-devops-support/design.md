## Context

Issue #72 lists three install options, cheapest first: (a) the `azure-devops`
extension on `azure-cli-core` only; (b) full `azure-cli` from Microsoft's apt
repo (~500 MB+ installed); (c) a third-party static client. The maintainer
chose (a), falling back to full `azure-cli` via uv only if core genuinely
could not run the extension.

## Goals / Non-Goals

**Goals:** `az devops` / `repos` / `boards` / `pipelines` in the image;
opt-in credentials matching the existing flag pattern; no hardcoded host.

**Non-Goals:** `az vm` / `az storage` / `az login` / service principals /
`ARM_*`; host-side PAT discovery (see D4).

## Decisions

### D1: azure-cli-core + extension, not azure-cli

Verified in a scratch venv: `azure-cli-core` 2.90.0 + the `azure-devops` 1.0.8
wheel runs `az devops -h`, and `az devops project list` completes a real
authenticated round-trip against `dev.azure.com` with a PAT from
`AZURE_DEVOPS_EXT_PAT`. It needs three modules full `azure-cli` would
otherwise supply: `python-dateutil` and `msrest` (imported by the extension)
and `azure-common` (imported by core's error handler). Installed size: venv
~40 MB, extension ~12 MB, uv-managed CPython 3.13 ~90 MB — ~140 MB total, vs
~500 MB+ for option (b).

Core ships no `az` entry point and no `az extension` command group (both live
in `azure-cli`), so:

- `/usr/local/bin/az` is a two-line `sh` wrapper calling
  `azure.cli.core.get_default_cli().invoke(argv)` with `python -I`.
- The extension wheel is installed with `uv pip install --target` into
  `/opt/az/cliextensions/azure-devops` (what `az extension add` would write),
  from a pinned URL + sha256 — stronger than `az extension add`, which fetches
  whatever the unpinned extension index serves. `AZURE_EXTENSION_DIR` points
  there from the wrapper, so it is not under `/root` (a volume at runtime).

The build ends with `az devops -h`, which fails if the extension does not load.

### D2: uv-managed Python under /opt/az, off PATH

The image has no Python. uv (already pinned) fetches a checksum-verified
CPython whose patch version is fixed by the uv pin. It lives in `/opt/az`,
root-owned and read-only to the session; nothing is added to PATH except the
`az` wrapper. `-I` keeps `PYTHONPATH` and the volume-backed user
site-packages (`/root/.local`) out of the interpreter.

### D3: Two pins, two new candidate kinds

`azure-cli-core` and the extension are separate release streams, so they are
two `Tool` rows (`az`, `azure-devops`) with their own fragments and soak.
`pypi` reads PyPI's JSON API (first-upload date per release, yanked releases
dropped). `azext` reads GitHub releases of `Azure/azure-devops-cli-extension`,
whose tags are build numbers (`20260902.1`), so the version comes from the
`.whl` asset name. The wheel URL is the `azcliprod` CDN path that
`az extension add` itself uses; its sha256 matches the extension index's
`sha256Digest`. Both answer on one `az --version` probe; their `version_re`s
use `[0-9.]+` rather than `[^ ]+`, which would run past the newline in the
multi-line report.

`azure-cli-core` is version-only, like the npm tools; its transitive deps
resolve at build time within core's own (mostly exact) pins.

### D4: Env-var PAT; no discovery

There is no `az` analogue of `gh auth token` that prints a usable PAT —
`az devops login` consumes one from stdin. So `--az` forwards
`AZURE_DEVOPS_EXT_PAT` (the extension's native PAT variable) by bare name.
Where the PAT comes from on the host is #73's concern (`op://` resolution).
`az devops login` itself does not work in the image: it wants `keyring`, which
the extension tries to `pip install` at runtime, and there is no pip in the
venv. That is acceptable — it would only persist a PAT onto the shared volume.

### D5: AZURE_DEVOPS_ORG_URL is the one hostname source

Azure DevOps Server is on-prem with a custom hostname; this repo has been
bitten by hostname assumptions twice (`--gh-direct`, `--tfe`). Nothing
hardcodes `dev.azure.com`. The extension has no `AZURE_DEVOPS_ORG_URL`; its
default-organization setting's env override is knack's
`AZURE_DEVOPS_EXT__DEFAULTS_ORGANIZATION`. The wrapper maps the former onto
the latter when set (an explicit `AZURE_DEVOPS_EXT__DEFAULTS_ORGANIZATION`
wins). Verified: `az devops project list` with only `AZURE_DEVOPS_ORG_URL`
set resolves the org.

### D6: Scoped mount and mask

`--az` mounts `~/.azure/azureProfile.json` and `~/.azure/clouds.config` `:ro`
when present, never `msal_token_cache.json` / `accessTokens.json`. Verified
that az runs with both files read-only (it writes only siblings: `config`,
`commands/*.log`, `azuredevops/`). Without `--az`, `/root/.azure` is
tmpfs-masked like `glab`/`tfe`; with it, the directory is unmasked so
`az devops configure --defaults` persists. No AAD token cache can be created
in-container, because `az login` is not in core.

### D7: Layer placement

Between the Go layer and the npm layer, same reasoning as Go: az moves
roughly monthly, claude-code near-daily, so a claude-code bump does not
rebuild az, and an az bump leaves the apt/gh/glab/aws/uv/Go layers cached.

## Risks / Trade-offs

- **Python CVEs.** A Python interpreter and ~40 PyPI packages are new scanner
  surface. Grype's existing `python`/`binary` rule already covers interpreter
  binaries; any PyPI findings are handled per-ID if CI surfaces them.
- **Unsupported entry point.** The wrapper stands in for azure-cli's
  `__main__`; it skips telemetry upload (a feature here). A core release that
  changes `get_default_cli()` would break it — caught by the build-time
  `az devops -h` and CI's version probe.
- **Combined with `--gh`:** no interaction — different hostnames, and the
  sidecar's `--add-host` redirection only covers GitHub hosts.
