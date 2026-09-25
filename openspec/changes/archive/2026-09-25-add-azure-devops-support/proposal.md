## Why

claude-docker covers GitHub, GitLab, Terraform Cloud and AWS, but teams on
**Azure DevOps** (Services or on-prem Server) have no path at all: no `az` in
the image and no opt-in flag, so the agent cannot list work items, read a
pipeline, or open a PR against an Azure DevOps repo (GitHub issue #72).

## What Changes

- **Install `az` with the `azure-devops` extension** — `azure-cli-core` from
  PyPI (version-pinned) in a uv-managed Python venv under `/opt/az`, plus the
  extension wheel from a pinned URL + sha256. **Not** the full `azure-cli`
  distribution: this layer is ~140 MB (most of it the Python runtime), against
  ~500 MB+ for full `azure-cli` from Microsoft's apt repo. Verified that
  `az devops` / `repos` / `boards` / `pipelines` run on core alone once three
  modules the extension imports (`python-dateutil`, `msrest`, `azure-common`)
  are added. `az vm`, `az storage`, `az login`, `az extension` are not present.
- **Two new automated pins**, `pins/az.env` (`azure-cli-core`, PyPI publish
  date) and `pins/azure-devops.env` (extension wheel, GitHub release date +
  sha256), each with a `Tool(...)` row so pin refresh and CI's version probe
  cover them. Two new candidate kinds in `update_pins.py`: `pypi` and `azext`.
- **`--az` opt-in flag** in `run.sh`: forward `AZURE_DEVOPS_EXT_PAT` and
  `AZURE_DEVOPS_ORG_URL` by bare name when set; mount
  `~/.azure/azureProfile.json` and `~/.azure/clouds.config` read-only when
  present; **never** `msal_token_cache.json` / `accessTokens.json` (the same
  line `--aws` draws around `~/.aws/credentials`). `az` statusline tag, help
  text.
- **`AZURE_DEVOPS_ORG_URL` is the single source of the hostname.** Nothing
  hardcodes `dev.azure.com`. The extension has no such variable itself, so the
  `az` wrapper maps it onto the extension's own default-organization override.
- **Mask `/root/.azure` with tmpfs** when `--az` is not set.
- Smoke coverage (`az` opt-in fixture, masked/granted assertions) and the
  README opt-in table, plus the threat model in `docs/security.md`.

Out of scope, deliberately: general Azure resource management (`az vm`,
`az storage`, service-principal auth for Terraform). It needs the full
`azure-cli`, drags in `ARM_*` / `AZURE_CLIENT_SECRET` and a much larger
threat-model surface; a separate issue if wanted.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `external-cli-tools`: adds `az` (+ `azure-devops` extension) to the bundled
  CLIs, the `--az` opt-in, and the `/root/.azure` mask.
- `cli-help`: `--az` joins the enumerated wrapper flags.
- `version-pin-refresh`: PyPI-backed tools record a version only, like npm
  tools; the `azure-devops` wheel is a hashed arch-independent artifact.

## Impact

- **Code**: `Dockerfile` (new layer between Go and npm), `run.sh`,
  `update_pins.py`, `pins/az.env`, `pins/azure-devops.env`, `smoke/*.sh`,
  `.github/workflows/ci.yml` (all-optins smoke cell gains `az`).
- **Tests**: `tests/test_masks.py` (mask set), `tests/test_update_pins.py`
  (version samples, CI-probe stub handles two tools sharing one probe, the two
  new candidate kinds).
- **Image size**: +~140 MB uncompressed.
- **No breaking changes**: purely additive; defaults unchanged.
