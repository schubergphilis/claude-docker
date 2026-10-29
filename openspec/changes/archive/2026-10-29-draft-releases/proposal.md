## Why

`release.yml` runs `mcvs-general-action`'s auto-release on every push to `main`. It tags the
next version and publishes a GitHub Release straight away, so almost every merge is a release:
15 between 2026-10-06 and 2026-10-28, six of them in three days. The action has no setting for
releasing less often or by hand.

The version is also decided without anyone seeing it first. On 2026-10-28 a `BREAKING CHANGE:`
footer in one commit of a merged stack took the project from v0.4.0 to v1.0.0. A breaking
change was real, but declaring 1.0, with the stability it implies, wasn't a decision anyone made.

Automatic versioning from Conventional Commits is worth keeping. What should move to a person
is the moment of release.

## What Changes

- `release.yml` keeps one draft GitHub Release up to date on every push to `main`, through a
  local composite action, `.github/actions/draft-release`. The draft holds the next version and
  the notes, counted from the Conventional Commit titles of the pull requests merged since the
  highest published release, with a dry-run mode on manual dispatch.
- Nothing is published automatically. A maintainer publishes the draft when a release is
  wanted. That creates the tag under their account, which starts `docker.yml` through its
  existing `tags: [v*]` trigger, so `release.yml` no longer dispatches it.
- Below 1.0.0, a breaking change bumps the minor version, so 1.0.0 is never drafted on its own.
  The project is past 1.0.0 now, so this matters only as a description of the action's rules.
- A breaking change counts when the pull request says so: `!` in its title, or a
  `BREAKING CHANGE:` footer in its description. A footer inside one of its commits no longer
  counts on its own, since the pull request is the unit that is reviewed and merged.
- The action's tests (a stub `gh`, no network) run in CI.
- `docs/maintenance.md` explains how to publish a release. `docs/installation.md` no longer
  names a failed dispatch as the cause of a tag with no image.

## Capabilities

- `image-distribution`:
  - MODIFIED *The image is published on a version tag*: a tag from a published draft starts the pipeline itself; the auto-release dispatch is gone.
  - MODIFIED *Publication is gated on the lint and scan stages*: a tag with no pipeline run is described without the dispatch.
  - ADDED *Releases are drafted, and published by a maintainer*.

## Impact

- `.github/workflows/release.yml`, `.github/actions/draft-release/` (new), `tests/draft-release/` (new), `.github/workflows/ci.yml`.
- `docs/maintenance.md`, `docs/installation.md`.
- `mcvs-general-action` is no longer used for releases. It stays in `general.yml` for linting.
