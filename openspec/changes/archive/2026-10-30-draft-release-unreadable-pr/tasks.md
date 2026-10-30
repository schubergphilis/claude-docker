## 1. Spec

- [x] 1.1 MODIFIED *Releases are drafted, and published by a maintainer*: scenario for an unreadable merged pull request
- [x] 1.2 `openspec validate draft-release-unreadable-pr --strict` passes

## 2. Action

- [x] 2.1 Keep the read's stderr; for a `Merge pull request #N` subject, list the pull request under the title in the merge message (type and `!` from it) and warn with the error, on and off the first-parent line
- [x] 2.2 Open the draft with a warning block naming each unreadable pull request and its error

## 3. Docs

- [x] 3.1 `docs/maintenance.md` *Releasing*: re-run before publishing a draft that opens with the warning

## 4. Verification

- [x] 4.1 `tests/draft-release/test_notes.sh`: unreadable merges inside a branch and on the first-parent line are listed under their merge titles (a `!` there makes a major) and warned about, the marker stays last, the block names both with the error, a readable merge is unaffected, an unreadable `(#N)` inside the branch stays a silent skip, no block when every read succeeds; the new checks fail against the previous action
