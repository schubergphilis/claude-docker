## Why

The Claude Code Docker setup in `~/claude-docker/` only supports one workspace and lacks the CLI tooling needed for real work. Cross-project `--resume` (Ctrl+A) also can't resume sessions whose workspaces aren't currently mounted.

## What Changes

- Persist every session in one shared volume so Ctrl+A lists the full history.
- Accept N workspace args in `run.sh`, mounted at `/workspaces/<basename>`.
- Install `gh`, `glab`, `aws` v2 in the image; bind-mount host creds and forward auth env vars when present.
- **BREAKING**: container path moves from `/workspace` → `/workspaces/<basename>`.

## Capabilities

### New Capabilities

- `persistent-session-storage`: shared on-disk store (named volume) for all sessions, creds, project records across runs.
- `multi-workspace-mounts`: variadic host-dir args, each mounted at a stable container path; first is cwd.
- `external-cli-tools`: `gh`, `glab`, and AWS CLI v2 available with host cred passthrough where supported.

## Impact

- Files: `Dockerfile`, `run.sh`.
- Rebuild required.
- Existing sessions keyed to `/workspace` don't surface under the new path.
