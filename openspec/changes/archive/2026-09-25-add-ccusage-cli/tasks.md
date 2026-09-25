## 1. Pin tooling

- [x] 1.1 Add `Tool("ccusage", "npm", "ccusage", "ccusage --version", r"^ccusage ([^ ]+)$")` to `update_pins.py` and a `CCUSAGE_VERSION` case to `fragment_lines()`.
- [x] 1.2 Update `tests/test_update_pins.py` for four npm tools and add a `ccusage` version-output sample.
- [x] 1.3 Generate `pins/ccusage.env` with `update_pins.py` under the soak gate; leave the other fragments unchanged.

## 2. Dockerfile

- [x] 2.1 `COPY` and source `pins/ccusage.env` in the npm layer, and install `ccusage@${CCUSAGE_VERSION}` in the same `npm install -g --ignore-scripts` invocation.
- [x] 2.2 `chmod 0755` the native binary for the build's architecture, with a comment giving the reason.
- [x] 2.3 Fail the build unless `ccusage --version` prints `ccusage ${CCUSAGE_VERSION}`.

## 3. Documentation

- [x] 3.1 Add `ccusage` to the README's preinstalled tool list and to the npm-provenance lists.
- [x] 3.2 Note in the README that `ccusage` sees container sessions only, and fetches pricing data unless run with `--offline`.

## 4. Verification

- [x] 4.1 `python3 -m unittest discover -s tests -p 'test_*.py'` passes.
- [x] 4.2 `docker build -t claude-code:local .` succeeds.
- [x] 4.3 In a container started by `run.sh` (host UID), `ccusage --version` prints the pinned version and `ccusage monthly --json` succeeds.
- [x] 4.4 `python3 update_pins.py --list-tools` and `--list-npm-tools` include `ccusage`.
- [x] 4.5 `hadolint --config .hadolint.yaml Dockerfile` passes.

## 5. Archive readiness

- [x] 5.1 `openspec validate add-ccusage-cli --strict` reports no errors.
