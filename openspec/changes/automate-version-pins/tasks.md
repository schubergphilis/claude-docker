## 1. Spec & design

- [x] 1.1 Proposal: capabilities (`version-pin-refresh` new, `package-managers` modified), motivation, impact
- [x] 1.2 Design: soak-the-selection model, fragment/consumption model, resolution taxonomy, major-bump policy, overrides, language choice
- [x] 1.3 Specs: `version-pin-refresh` requirements + `package-managers` delta

## 2. Refresh tool (`update_pins.py`)

- [x] 2.1 Single stdlib-only Python file with a PEP 723 uv header (`requires-python`, `dependencies = []`), run via `uv`; `argparse` CLI (`--soak`, `--block-major-bumps`, `--pin`, `--help`) with input validation (numeric soak; `--pin` must be `TOOL=VERSION`, name a known tool, appear at most once)
- [x] 2.2 Resolution per source: npm registry (claude-code, openspec, pnpm), GitHub releases (uv, glab, tfenv), aws-cli via dated `aws/aws-cli` tags (paginated). Select the newest stable version older than the soak window; exclude prereleases; filter npm candidates to `.versions` (drop yanked/unpublished)
- [x] 2.3 `held` logic: when the only newer version is inside the soak window, retain the current pin and record it for the report
- [x] 2.4 Major-version policy: cross majors once soaked by default; `--block-major-bumps` constrains a run to each tool's current major and reports the crossed major as blocked (aws-cli is implicitly v2-locked by its tag filter)
- [x] 2.5 Hashing: for each binary tool (uv, glab, tfenv, aws-cli) download `amd64` + `arm64` artifacts regardless of host arch and compute sha256 per published arch; fail (no fragment written) if an expected arch is missing
- [x] 2.6 Write per-tool `pins/<tool>.env` fragments (version only for npm tools; version + per-arch download URL + sha256 for binary tools, each sha256 emitted next to the URL it was computed from so the build can source the URL rather than rebuild it)
- [x] 2.7 `--pin <tool>=<version>` override: re-resolve + re-hash a specific version, bypassing the soak (npm versions validated against the registry); mark it as an override in the report
- [x] 2.8 Operator report: per-tool `old → new` with age, `⬆ MAJOR` marker, `held` lines, `⚠` reminders for the manual pins, and base-image digest drift
- [x] 2.9 Fail-safe writes: stage fragments in a temp dir on the same filesystem as `pins/` and swap in via `os.replace` only on full success; a failed run leaves committed pins intact
- [x] 2.10 Hardened HTTP: https-only across redirects with a bounded redirect chain; honors `GITHUB_TOKEN` / `GH_TOKEN`
- [x] 2.11 On an unchanged version, re-verify the committed artifact hash (re-download the recorded URL, compare) instead of rewriting it — fail loudly on mismatch (a re-published artifact at the pinned version) and leave the pin untouched; tolerate a download blip on a no-op run

## 3. Dockerfile integration

- [x] 3.1 Seed `pins/*.env` from the versions currently pinned in the Dockerfile (behavior-preserving)
- [x] 3.2 Remove the automated tools' inline version/sha `ARG`s (keep nodejs version and the base-image digest inline)
- [x] 3.3 `COPY` + source each fragment immediately before its consuming `RUN`, preserving layer ordering and cache granularity; binary tools `curl` the URL sourced from the fragment (not a URL reassembled inline) so the pinned sha256 covers exactly what is fetched

## 4. Tests

- [x] 4.1 `tests/test_update_pins.py` (stdlib `unittest`): date parsing, semver selection, within-major selection, major-bump detection, and `--pin` arg validation (unknown tool / duplicate / missing version)
- [x] 4.2 Extract the soak / `held` / `--block-major-bumps` decision into a pure, network-free seam (`select_version`) and table-test it against the spec scenarios (newest-soaked, held, no-op, major-cross-by-default, major-blocked, within-major fallback, prerelease exclusion, nothing-soaked)

## 5. CI

- [x] 5.1 Run the unittest suite (`python3 -m unittest discover`); ShellCheck the remaining shell scripts
- [x] 5.2 npm supply-chain audit for all three npm tools: ≥5-day soak + `npm audit signatures`, reading versions from `pins/*.env`
- [x] 5.3 Version smoke test reads the claude-code pin from `pins/claude-code.env`

## 6. Documentation

- [x] 6.1 README "Updating pinned tool versions": the registry-vs-direct-download distinction, the refresh workflow, the soak window, `--pin` / `--block-major-bumps`, and the manual pins

## 7. Verification

- [x] 7.1 `update_pins.py` end-to-end against live APIs: soak / `held` / `⬆ MAJOR` / `--block-major-bumps` / `--pin` override / fail-safe
- [x] 7.2 unittest suite green; shellcheck clean at `severity=warning`
- [x] 7.3 `docker build` succeeds and tool `--version` checks pass; a tampered `pins/<tool>.env` fails the build at `sha256sum -c`; changing one fragment leaves the npm layer cached — CAVEAT: build validated on `amd64` only (arm64 relies on maintainers' local builds for now)

## 8. Deferred to dedicated follow-up changes

- [ ] 8.1 Independent hash cross-checks at record time — verify uv release attestations (`gh attestation verify` / cosign) and the aws-cli PGP-signed installer before trusting a self-computed sha. Deferred because it adds new tool dependencies + per-tool verification logic (a new capability, not "finishing" the resolver)
- [ ] 8.2 Weekly automated refresh (CI/cron) opening a PR, so freshness doesn't depend on someone remembering to run the script — the fragments + script were built to support it
