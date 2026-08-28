## Why

`update_pins.py` and the `pins/*.env` fragments were built so a refresh could run
unattended, but nothing runs it. Freshness therefore depends on someone
remembering — and the soak window makes that worse, not better: a version that
cleared its 7 days three months ago is exactly as invisible as one that cleared
it yesterday. `automate-version-pins` recorded this as deferred work
(`tasks.md` 8.2, "Weekly automated refresh (CI/cron) opening a PR"); this change
is that follow-up.

Every requirement in the `version-pin-refresh` capability today is phrased
*"the operator runs the refresh script"*. Adding a second, unattended actor —
plus an operator-configured repository secret it needs to be useful — is a
change to that capability, not a CI-plumbing detail, so it gets a requirement
rather than riding along uncovered.

## What Changes

- Add `.github/workflows/pins-updater.yml`: a Monday cron plus
  `workflow_dispatch` (with `soak` and `block-major-bumps` inputs) that runs
  `python3 update_pins.py` and, when any `pins/*.env` fragment moved,
  force-pushes the `bump/pins` branch and opens or refreshes a single PR
  carrying the script's full report.
- One long-lived branch and one PR, replaced each run, rather than a dated
  branch per run: a stale pins PR proposes versions the next refresh has already
  superseded.
- Open the PR with `PINS_UPDATER_TOKEN` when that secret exists, falling back to
  `GITHUB_TOKEN`. The fallback is documented as degraded rather than equivalent:
  GitHub does not fire `pull_request` workflows for a PR opened with
  `GITHUB_TOKEN`, and `main`'s ruleset requires two contexts that then never
  report, so the PR cannot be merged until a human nudges it.
- Document both the workflow and the secret in README's "Updating pinned tool
  versions" section.

Not in scope: acting on the manual pins (`nodejs`, `task`, `go`, the base-image
digest). The run reports them exactly as an operator run does and rewrites
nothing — automating those is a separate question per pin, and two of them
cannot be soak-gated at all. Also not in scope: auto-merging a green pins PR.
A human reads the diff.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `version-pin-refresh`: adds a requirement that the refresh runs on a schedule
  without an operator, and that its outcome reaches a reviewable pull request.
  Additive — no existing requirement changes, and the scheduled run is defined
  as equivalent to an operator run so the soak, override, and fail-safe
  requirements continue to govern both actors.

## Impact

- `.github/workflows/pins-updater.yml` — new file, the whole of the behaviour.
- `README.md` — the refresh section gains the unattended path and the
  `PINS_UPDATER_TOKEN` caveat.
- No change to `update_pins.py`, the Dockerfile, the built image, or anything at
  runtime. The workflow is a caller of the existing script, not a change to it.
- Operational prerequisite, not code: `PINS_UPDATER_TOKEN` must exist as a repo
  secret (fine-grained PAT scoped to this repo, `contents: write` +
  `pull requests: write`) for the weekly PR to be mergeable without manual
  intervention.

## Sequencing

`automate-version-pins` is unarchived and carries the rest of this capability's
requirements as a delta. This change deltas against the already-synced
`openspec/specs/version-pin-refresh/spec.md` and is independent of it: whichever
archives first, both deltas are additive and merge into the same capability. The
requirement existing here before either archive is the point — otherwise the
synced spec would describe pin refresh as a manual, operator-only flow on the
day the automation goes live.
