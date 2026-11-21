## Why

A bump for an older tag can run again after a newer tag's bump opened its pull
request: a maintainer starts it by hand, or that tag's publish finishes late
(#265). The bump only compares the tag with `main`'s formula, and `main` still
names the release before both, so it pushes `homebrew/<older tag>` and opens a
second pull request. It closes only older bumps, so the newer one stays open
beside it.

Merging either makes the other conflict, so no Homebrew user is moved back,
but a maintainer has to notice and close the stale one by hand.

## What Changes

- **An older bump gives way to a newer one.** Before it pushes anything, the
  bump looks for an open bump pull request on this repository targeting `main`
  for a newer tag. If there is one, it stops and says so in the job summary:
  no branch is pushed and no pull request opened or edited.
- **Only real bump branches count.** The open bumps it closes or gives way to
  are same-repository `homebrew/vX.Y.Z` branches into `main`; a fork's pull
  request is still left alone, and does not hold a bump back.
- **A workflow-level test.** `tests/test_homebrew_workflow.py` runs the step
  that opens the pull request against a stub `gh` and `git`, through the
  sequence in #265.

## Capabilities

### Modified Capabilities

- `homebrew-distribution`: *Only published stable releases reach the formula*
  also holds back a bump while a newer one is open.

## Impact

- `.github/workflows/homebrew.yml`
- `tests/test_homebrew_workflow.py`
- `docs/maintenance.md`
