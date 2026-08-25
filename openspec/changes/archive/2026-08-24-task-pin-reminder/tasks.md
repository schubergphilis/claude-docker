## 1. Resolver

- [x] 1.1 Add `import gzip` to `update_pins.py`'s stdlib imports (keep `dependencies = []` in the script header untouched).
- [x] 1.2 Add a `base_image_codename()` helper that parses the suite out of the pinned `FROM ubuntu:<codename>-<date>@sha256:<digest>` line and returns `""` when the tag's leading token is not purely alphabetic (so `ubuntu:26.04@…` degrades instead of 404ing).
- [x] 1.3 Add `task_latest_published(codename)` — fetch `https://dl.cloudsmith.io/public/task/task/deb/ubuntu/dists/<codename>/main/binary-amd64/Packages.gz` via the existing `http_bytes()`, `gzip.decompress()` it, collect every `^Version:` value, and return `max_stable(...)`. Return `""` on any exception or when the codename is empty, mirroring `go_latest_stable()`'s contract.

## 2. Reminder line

- [x] 2.1 In `print_reminders()`, read `ARG TASK_VERSION=` out of the Dockerfile alongside the existing `NODE_VERSION` / `GO_VERSION` / base-digest parsing.
- [x] 2.2 Print the `task` reminder between the `nodejs` and `go` lines (Dockerfile ARG order), with three branches matching the `go` line's shape: newest resolved and differs (name both versions, point at `ARG TASK_VERSION`), newest resolved and matches, and could-not-resolve (name the derived codename so a parse failure is distinguishable from an outage). Keep the column alignment of the existing lines.
- [x] 2.3 Confirm by inspection that no code path in the new resolver or reminder can raise out of `print_reminders()` or alter `main()`'s return value.

## 3. Tests

- [x] 3.1 Add a `TestTaskLatestPublished` case in `tests/test_update_pins.py` covering: a fixture index (inline gzipped bytes, no network — patch `up.http_bytes`) resolving to the newest version; an index whose entries are not newest-first still resolving to the highest; a non-semver/prerelease entry being ignored; and an empty/garbage index returning `""`.
- [x] 3.2 Add tests for `base_image_codename()`: the current `resolute-<date>@sha256:` form yields `resolute`, and a `26.04@sha256:` form yields `""`.
- [x] 3.3 Add a degradation test: patch `up.http_bytes` to raise `urllib.error.URLError`, assert `task_latest_published()` returns `""` and does not propagate.
- [x] 3.4 Add a `print_reminders()` output test (capture stdout as `TestAudit`/`TestListNpmTools` already do) asserting the drift branch names both versions and the could-not-resolve branch names the codename — with all three upstream resolvers patched so the test stays offline.
- [x] 3.5 `python3 -m unittest discover -s tests -p 'test_*.py' -v` passes.

## 4. Documentation

- [x] 4.1 Update the `task` block comment in the Dockerfile (`Dockerfile:22-26`): `update_pins.py` still never rewrites this pin, but it no longer "leaves this alone" — it now reports staleness. Keep the `Bump with:` one-liner, and note that the script queries that same index.
- [x] 4.2 Update the manual-pins paragraph in README.md's "Updating pinned tool versions" section to include `task` alongside `nodejs`, Go, and the base digest, naming the apt repo as the source and the missing publish dates as the reason it stays manual.

## 5. Verification

- [x] 5.1 Run `uv run update_pins.py` (network) and confirm the `task` line appears in the reminder block, reports `3.53.1` against the repo's newest published version, and that `git diff` shows no change to the Dockerfile.
- [x] 5.2 Run with `dl.cloudsmith.io` unreachable (e.g. patch the URL to an unroutable host or run offline) and confirm the run completes with the same exit status and prints the could-not-resolve reminder.
- [x] 5.3 `openspec validate task-pin-reminder` passes and all tasks in this file are checked off.
