## 1. Implementation

- [x] 1.1 Replace the `case "$name"` allowlist check at `claude-docker/run.sh:136-140` with a denylist that rejects only `*:*` and empty basenames.
- [x] 1.2 Update the error message to name the actual disallowed character (`:`) or condition (empty), not the fictitious `[A-Za-z0-9._-]` allowlist.

## 2. Spec sync

- [x] 2.1 After the change is applied, merge `specs/multi-workspace-mounts/spec.md` (delta) into `openspec/specs/multi-workspace-mounts/spec.md` so the canonical spec carries the new requirement.

## 3. Verification

- [x] 3.1 Manually verify positive case: `mkdir "/tmp/AI Policy" && claude-docker "/tmp/AI Policy" -- --help` starts a container, no rejection from `run.sh`. (verified statically: validation passes, script reaches `docker run`)
- [x] 3.2 Manually verify positive case with parens/unicode: `mkdir "/tmp/Project (v2)" && claude-docker "/tmp/Project (v2)" -- --help` succeeds. (verified statically with `Project (v2)` and `2026年計画`)
- [x] 3.3 Manually verify negative case: invoking `claude-docker` against a directory whose basename contains `:` exits non-zero with the new error message before `docker run` is reached. (verified: error reads `workspace basename 'foo:bar' cannot contain ':' (breaks docker -v parsing)`, exit 1)
- [x] 3.4 Manually verify the collision detection is unaffected: pointing two args at sibling dirs with the same basename still errors as before (regression check). (verified: collision message unchanged, exit 1)
- [x] 3.5 Confirm in the running container that `pwd` shows `/workspaces/AI Policy` and that `git status` / file reads work as expected inside it (sanity check on quoting through `-w` and `--add-dir`). (verified on macOS host: `claude -p` inside the container reported `Empty repo at /workspaces/AI Policy on main` — confirms `-v` mount, `-w` cwd, and in-container git all honor the space)
