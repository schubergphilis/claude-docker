## Why

`claude-docker` currently rejects any workspace whose basename contains characters outside `[A-Za-z0-9._-]`, citing "characters that break 'docker -v' parsing". The allowlist is over-broad: `docker -v` only splits on `:`, and every other consumer in the pipeline (`-w`, `--add-dir`, the in-container shell) receives the path as a single quoted argv element. The current rule blocks common, legitimate directory names — `AI Policy`, `Project (v2)`, `client+vendor`, `2026年計画` — for no real reason.

## What Changes

- Replace the `[A-Za-z0-9._-]`-only allowlist in `claude-docker/run.sh` with a targeted reject-on-`:` rule. Empty basenames stay rejected (a `/workspaces/` mount target is meaningless).
- Update the error message to name the actual blocker (`:`) rather than an invented allowlist.
- Update `multi-workspace-mounts` spec: introduce an explicit "Reject basenames containing `:` or empty" requirement (the previous behavior was implicit and over-strict; nothing in the current spec text mandated the allowlist).

This is **not** a breaking change for any user whose directories already pass the old check — the new rule is strictly more permissive. Users who had to rename `AI Policy` to `AI-Policy` to use the tool can now use the original name.

## Capabilities

### New Capabilities

(none — this is a constraint loosening on an existing capability)

### Modified Capabilities

- `multi-workspace-mounts`: replace the implicit basename-character restriction with an explicit, narrower rule that only rejects `:` and empty.

## Impact

- `claude-docker/run.sh`: ~5 lines around the `case "$name"` block (lines 136-140).
- `claude-docker/openspec/specs/multi-workspace-mounts/spec.md`: one new requirement section with two scenarios.
- No Dockerfile change. No README change required (README does not currently document the allowlist).
- No persisted-volume migration. The container path `/workspaces/<basename>` is ephemeral; nothing on disk depends on the prior naming constraint.
