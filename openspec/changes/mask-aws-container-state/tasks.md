## 1. Spec

- [x] 1.1 Proposal: the host/container asymmetry, the two false scenarios, why the outcome lives in one requirement and the mechanism in another, and why the severity is a boundary break rather than a live credential leak
- [x] 1.2 Spec delta: `Credentials opt-in` gains the non-persistence rule and has the two scenario assertions corrected; `In-container gh login persists only under --gh` gains AWS and a no-host-conditional-masking rule, plus two AWS scenarios
- [x] 1.3 Record the conditional `~/.aws/sso` host mount as out of scope, so the partial fix is stated rather than implied

## 2. Wrapper

- [x] 2.1 `run.sh`: `--tmpfs /root/.aws` when `WITH_AWS=0`, inside the existing `EPHEMERAL=0` block so `--ephemeral` (which mounts no volumes at all) is unaffected
- [x] 2.2 `run.sh`: `--tmpfs /root/.aws/cli/cache` when `WITH_AWS=1`, narrow enough to leave the `:ro` host mounts at `/root/.aws/config` and `/root/.aws/sso` visible
- [x] 2.3 Comment the pair with why AWS differs from gh/glab/tfe: no in-container login step, so the mask is unconditional rather than three-state

## 3. Tests

- [x] 3.1 `tests/test_masks.py`: assert the exact mask set in `run.sh` with each mask's guard, so removing or weakening one fails
- [x] 3.2 Same file: assert every mask in `run.sh` also appears in `smoke/smoke.sh`, closing the drift that let this gap survive
- [x] 3.3 `smoke/smoke.sh`: mirror both new masks
- [x] 3.4 `smoke/assert-in-container.sh`: dedicated AWS assertion — `/root/.aws` empty without `--aws`, `/root/.aws/cli/cache` empty with it. Not reachable by repointing `optin_config_path`, whose value is shared with the granted branch that asserts the path is read-only
- [x] 3.5 Confirm the pre-change smoke suite could not have caught this, and record it in the proposal rather than only in the commit message
- [x] 3.6 Assert the `--aws` cache mask stays *writable*. It is the only mask that must accept writes — the AWS CLI writes derived STS into it — and `entrypoint.sh`'s chown walk uses `find -xdev`, so it never descends into a tmpfs and cannot fix ownership there. Relies on Docker's default `--tmpfs` mode; asserted rather than assumed

## 4. Documentation

- [x] 4.0 README `--aws` row: what the mask hides without the flag and what it narrows to with it, matching how the `--glab` and `--tfe` rows already read

## 5. Verification

- [x] 5.1 `shellcheck --severity=warning` (CI's threshold) over `run.sh`, `entrypoint.sh` and both smoke scripts — clean. Not installed in the dev image and no root/pip available there; `uv tool run --from shellcheck-py shellcheck` works
- [x] 5.2 `python3 -m unittest discover -s tests -p 'test_*.py'` — 106 tests, all pass
- [x] 5.3 `openspec validate mask-aws-container-state --strict`
- [x] 5.4 Assert the new test fails against the unfixed `run.sh` — a mask test that passes before the fix tests nothing. Confirmed: `test_mask_set_is_exactly_the_reviewed_set` and `test_aws_is_masked_in_both_directions_with_a_narrower_scope_under_aws` fail on `HEAD:run.sh`, the other four pass
- [x] 5.5 `bash -n` on every edited shell script
- [ ] 5.6 `docker build -t claude-code:local .` and `IMAGE=claude-code:local bash smoke/smoke.sh --uid="$(id -u)" --optins=aws,glab,tfe` — needs a Docker daemon, so left to CI's `docker-build` job

## 6. Follow-ups (not this change)

- [ ] 6.1 The conditional-on-host-state masking pattern elsewhere in `run.sh` (config overlays, the `settings.json` reseed) — one change of its own
- [ ] 6.2 `hadolint` is unaffected here (no Dockerfile change) but is part of the pre-PR check list
