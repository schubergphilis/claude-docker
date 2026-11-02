## Why

The draft-release action reads each merged pull request for its title, author and `BREAKING CHANGE:` footer. When that read fails, a pull request merged inside another branch is skipped silently, and one on the default branch is listed under its merge-commit subject with its type and breaking flag lost. stderr goes to `/dev/null`, so a 404 and a 5xx look the same. The draft can then miss a shipped pull request, or count too low a version, and nothing shows it (#244, from review of #234).

## What Changes

- A `Merge pull request #N` commit whose pull request can't be read is always listed, on or off the default branch's first-parent line, under the title GitHub wrote into the merge commit's message. That title gives the type and any `!` marker; only a `BREAKING CHANGE:` footer in the description stays unknown. The run carries a warning that includes the error.
- The draft opens with a warning block naming each such pull request and its error, and asks for a re-run before publishing. A maintainer reviews the draft before publishing, so that is where the gap has to be visible.
- Squash-style `(#N)` subjects keep today's behaviour: inside a merged branch `#N` may be an issue, so an unreadable one is still skipped.

## Capabilities

- `image-distribution`: MODIFIED *Releases are drafted, and published by a maintainer* (scenario: a merged pull request that cannot be read is named in the draft).

## Impact

- `.github/actions/draft-release/action.yml`, `tests/draft-release/test_notes.sh`, `docs/maintenance.md`.
