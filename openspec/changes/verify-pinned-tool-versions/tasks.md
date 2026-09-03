## 1. Registry

- [ ] 1.1 Convert `TOOLS` in `update_pins.py` from `(name, kind, ref)` tuples to a
  `NamedTuple` record, and update every positional unpacking site (`run_list_npm_tools`,
  `run_audit`, `parse_args`, `main`) to named access; verify by running
  `python3 -m unittest discover -s tests -p 'test_*.py'` and seeing the pre-existing
  71 tests still pass
- [ ] 1.2 Give each of the seven records a `probe` (whitespace-separated argv, e.g.
  `openspec --version`) and a `version_re` (one capture group, anchored on the tool's
  literal prefix), keeping `claude-code`'s rule anchored on its ` (Claude Code)` suffix so
  the existing assertion is not weakened; verify each rule against that tool's recorded
  real output in a unit test that asserts the captured group equals the version

## 2. Listing mode

- [ ] 2.1 Add a `--list-tools` early-return mode emitting one TSV row per tool
  (`name`, `probe`, `version_re`, `version`) for every tool in the registry, not only
  npm-backed ones; verify the new unit tests in group 3 pass
- [ ] 2.2 Make the producer fail closed on the same contract as `--list-npm-tools`:
  validate every pin first and emit nothing at all if any tool has no pinned version,
  exiting non-zero with a GitHub Actions error annotation on stderr; verify with the
  unit test in 3.2
- [ ] 2.3 Wire the flag through `parse_args` and `main`'s early-return ordering
  alongside `--list-npm-tools`, and add it to the module docstring's usage block; verify
  `python3 update_pins.py --list-tools` prints seven rows and `--help` documents the flag

## 3. Tests

- [ ] 3.1 Cover the listing: exactly seven rows, tool names in registry order, four
  tab-separated columns, and each row's version equal to the value in its `pins/*.env`
  fragment; verify the tests pass
- [ ] 3.2 Cover the fail-closed path: a tool with an empty version pin makes
  `--list-tools` exit non-zero having printed no partial output; verify the test asserts
  stdout is empty, not merely that the exit code is non-zero
- [ ] 3.3 Cover the rule invariants every entry must hold: exactly one capture group,
  no regex construct outside the subset bash ERE and Python `re` read identically, and a
  `probe` whose tokens contain no embedded spaces; verify the tests pass
- [ ] 3.4 Cover registry completeness: every tool in the registry has a non-empty
  `probe` and `version_re`, so a tool added later cannot be silently unverifiable; verify
  the test fails if a record is added with either field blank

## 4. CI

- [ ] 4.1 Replace `ci.yml`'s `Smoke test — claude --version matches Dockerfile pin` step
  with one that loops over `--list-tools`, runs each `probe` against `claude-docker:ci`,
  extracts with `[[ =~ ]]` / `BASH_REMATCH[1]`, and compares to the pinned version;
  verify by reading the rendered step against the four fail-closed properties in 4.2
- [ ] 4.2 Hold the step to the existing audit step's fail-closed shape: `set -euo
  pipefail`, the tool list captured with `$(...)` before the loop and consumed as a
  here-string (never a process substitution), a tool whose version cannot be extracted
  treated as a failure, and failures accumulated so every bad tool is reported in one run
  rather than only the first; verify each property is present by inspection of the step
- [ ] 4.3 Keep the step lint-clean by construction — split `probe` with `read -ra` into
  an array rather than relying on unquoted word-splitting, quote every other expansion,
  and keep lines within the file's existing conventions; verify by inspection, noting
  that `shellcheck`, `hadolint` and `yamllint` are not installed in this environment and
  the authoritative check is CI's `validate` job on the PR

## 5. Docs

- [ ] 5.1 Document `--list-tools` in `README.md`'s pinned-tool-versions section next to
  the existing modes, describing what CI uses it for; verify the section reads correctly
  and the surrounding command list stays accurate

## 6. Verification

- [ ] 6.1 Run `python3 -m unittest discover -s tests -p 'test_*.py' -v` and confirm the
  full suite passes with the new tests included
- [ ] 6.2 Prove the shared-rule assumption without an image: feed each tool's recorded
  sample output through the same `[[ =~ ]]` matching the CI step uses, with the
  `version_re` taken from `--list-tools` output, asserting a match yields the pinned
  version and a mutated version string does not; docker is unavailable in this
  environment, so the probe against a real image is gated by CI's `docker-build` on the PR
- [ ] 6.3 Run `openspec validate verify-pinned-tool-versions --type change --strict
  --no-interactive` and confirm it passes
