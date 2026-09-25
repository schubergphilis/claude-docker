## 1. Install + pin

- [x] 1.1 Verify in a scratch venv that `az devops -h` and an authenticated `az devops project list` work on `azure-cli-core` + the `azure-devops` wheel, and find the missing modules (`python-dateutil`, `msrest`, `azure-common`)
- [x] 1.2 `update_pins.py`: `pypi` and `azext` candidate kinds, `Tool("az", …)` and `Tool("azure-devops", …)` rows, fragment lines; generate `pins/az.env` and `pins/azure-devops.env`
- [x] 1.3 Dockerfile layer between Go and npm: sha256-verified wheel, uv-managed Python venv under `/opt/az`, `/usr/local/bin/az` wrapper (with the `AZURE_DEVOPS_ORG_URL` mapping), build-time `az devops -h`
- [x] 1.4 Replay the layer's RUN locally with paths remapped into a scratch dir; confirm `az --version` reports both pins and the layer is ~140 MB

## 2. Wrapper: --az

- [x] 2.1 `WITH_AZ=0`, `--az` case, help text, `az` statusline tag
- [x] 2.2 Forward `AZURE_DEVOPS_EXT_PAT` / `AZURE_DEVOPS_ORG_URL` by bare name
- [x] 2.3 `:ro` mounts of `~/.azure/azureProfile.json` and `~/.azure/clouds.config` when present; nothing else from `~/.azure`
- [x] 2.4 `--tmpfs /root/.azure` when `--az` is off

## 3. Tests and smoke

- [x] 3.1 `tests/test_masks.py`: `/root/.azure` in `EXPECTED_MASKS` and `SINGLE_LINE_MASKS`
- [x] 3.2 `tests/test_update_pins.py`: version samples for both tools, CI-probe stub supports two tools sharing one probe, candidate-kind tests
- [x] 3.3 `smoke/smoke.sh` `az` fixture + mask mirror; `smoke/assert-in-container.sh` `optin_config_path` + `ALL_OPTINS`; CI all-optins cell and CONTRIBUTING/`docs/maintenance.md` smoke commands gain `az`
- [ ] 3.4 CI: image build, `--list-tools` probe (both `az` rows), smoke cells, Trivy/Grype scans

## 4. Docs

- [x] 4.1 README: bundled CLIs, `--az` opt-in table row; `docs/security.md`: threat-model lines (exposed PAT, cross-session `~/.azure`, rotation, build-time pin kinds)
