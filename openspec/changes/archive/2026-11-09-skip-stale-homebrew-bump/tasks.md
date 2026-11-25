## 1. Spec

- [x] 1.1 MODIFIED `homebrew-distribution`: *Only published stable releases reach the formula*
- [x] 1.2 `openspec validate skip-stale-homebrew-bump --strict` passes

## 2. Workflow

- [x] 2.1 `.github/workflows/homebrew.yml`: list the open same-repository `homebrew/vX.Y.Z` pull requests into `main` before the bump, stop when one is newer, and close the older ones from the same list
- [x] 2.2 `tests/test_homebrew_workflow.py`: run the step against a stub `gh` and `git` — v1.2.0, then v1.3.0, then v1.2.0 again leaves only v1.3.0 open; a re-run edits its own pull request; a fork's newer branch does not hold a bump back
- [x] 2.3 The new test fails against the workflow before this change and passes after, in Ubuntu 24.04
- [x] 2.4 actionlint clean on `homebrew.yml`

## 3. Docs

- [x] 3.1 `docs/maintenance.md`: a bump gives way to an open bump for a newer tag

## 4. Archive

- [x] 4.1 `/opsx:archive` (syncs `openspec/specs/`)
