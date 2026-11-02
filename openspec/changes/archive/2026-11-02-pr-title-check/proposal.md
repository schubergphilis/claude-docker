## Why

Since `draft-releases`, the next version and the release notes are counted from the titles of
the merged pull requests. Nothing checks those titles. `MCVS-PR-validation-action` only checks
that the description isn't empty, and `lint-commit` runs commitlint on the commits, not the
title. A title like `Fix typo` lands under *Other changes* and bumps the patch version; a
misspelt `feat!:` loses its breaking change. Either way no check fails, and the mistake shows
only when a maintainer reads the draft, after the pull request has merged.

## What Changes

- A new workflow, `pr-title.yml`, checks every pull request title against Conventional
  Commits through a local composite action, `.github/actions/validate-pr-title`. It runs when
  a pull request is opened, reopened, pushed to, or edited, so a corrected title is checked
  again without a push.
- The allowed types are the Conventional Commits set that commitlint already enforces on the
  commits: `build chore ci docs feat fix perf refactor revert style test`. A scope stays
  optional, and `!` marks a breaking change.
- The action reads the title through the environment, never interpolated into the script,
  needs no token and no checkout.
- Only the title is checked. Commit subjects stay with `lint-commit`.
- The action's tests run in CI's Validate job.
- `CONTRIBUTING.md` and `docs/maintenance.md` say the title must be a Conventional Commit, and why.

## Capabilities

- `image-distribution`:
  - ADDED *Pull request titles are Conventional Commits*.

## Impact

- `.github/workflows/pr-title.yml` (new), `.github/actions/validate-pr-title/` (new),
  `tests/validate-pr-title/` (new), `.github/workflows/ci.yml`.
- `CONTRIBUTING.md`, `docs/maintenance.md`.
- To make the check blocking, a maintainer adds it to the branch's required status checks.
