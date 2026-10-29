# Tests for draft-release

```
tests/draft-release/run_tests.sh
```

Needs bash, jq and awk. No network, no GitHub, no `gh`: a stub stands in for the CLI.

## How it works

`harness.sh` lifts the step script straight out of [`.github/actions/draft-release/action.yml`](../../.github/actions/draft-release/action.yml) and runs it with the
action's inputs supplied as environment variables. The tests therefore run the action as it
is, not a copy of it: a change to the `run:` block is a change to what runs here.

`stub/gh` is first on `PATH` while the script runs. It answers reads from a fixture directory
through real `jq`, so the jq filters under test are the action's own. It records every write
to `calls.log` and performs none of them, so a test can assert which release a run *would*
have touched. It also fails outright if `gh release` is invoked: the action addresses
releases by id through `gh api`, and a reappearance of `gh release edit <tag>` is the defect
these tests exist to catch.

A test file writes fixtures, calls `run`, and reads the result through the helpers in
`lib.sh` — the outputs the action wrote, the writes it attempted, the notes it rendered, the
annotations it emitted. Every assertion is a string comparison; nothing is eyeballed.

| File | Covers |
|---|---|
| `test_baseline_and_writes.sh` | which published release becomes the baseline, and which release a write may address |
| `test_version_bumps.sh` | every way the version can move, from every kind of change that moves it |
| `test_notes.sh` | what the notes look like from a history with a bit of everything in it, and that a title written as shell stays text |

## What these tests do not cover

- **The real API.** The stub reimplements how `gh api` handles `-f`, `-F` and `@<file>`; it
  cannot validate GitHub's schema or a real response. This repository dogfoods the action on
  every push to `main`, which is where the write path is exercised for real.
- **`--paginate`.** The stub serves one page. A marker match on page two of a repository with
  more than a hundred releases is untested; the pagination is gh's, not ours.
- **Failures by status.** A failed write is modelled as "the call failed", not as a 404
  against a 422.

## Adding a case

Copy the shape of a neighbouring case: `fresh_fixtures` (or a `setup` helper on top of it),
fixtures, `run`, one or more `check`s. Name the case for the situation and the expectation
for what must hold, so a failure reads as a sentence.
