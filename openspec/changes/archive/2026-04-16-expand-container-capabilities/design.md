## Context

`~/claude-docker/` already has a hardened two-volume setup (`claude-code-root:/root` + `claude-code-home:/root/.claude`). This change extends it for multi-workspace work and adds VCS/cloud CLIs without weakening isolation.

## Goals / Non-Goals

**Goals:**
- Cross-project `--resume` (Ctrl+A) surfaces and can actually open sessions from any workspace the user passes at launch.
- One `run.sh` invocation covers multiple repos + sibling git worktrees.
- `gh`, `glab`, `aws` work in-container with minimal re-auth.

**Non-Goals:**
- Auto-discovering previously-used workspaces. User passes dirs explicitly.
- Migrating old `/workspace` sessions to the new path.
- Host ↔ container cred sync beyond initial launch-time passthrough.

## Decisions

- **Container path = `/workspaces/<basename>`**, first arg becomes cwd. Deterministic → stable session keys across runs (Ctrl+A matches).
  - Alt considered: `/workspaces/ws0`, `ws1`… rejected — basenames are human-readable and match host muscle memory.
- **Resume requires mounting**: if Ctrl+A lists a session whose workspace isn't mounted, resume fails loudly. Acceptable: user re-launches with the missing dir as an arg.
  - Alt: auto-mount every known project from `/root/.claude/projects/`. Rejected — requires a host-path registry, hidden magic, broken if host paths moved.
- **Per-CLI auth strategy**:
  - `glab`, `aws`: file-based on macOS → bind-mount `~/.config/glab-cli` and `~/.aws` when present (RW, so token refresh works).
  - `gh`: Keychain-backed on macOS → no host file → fresh `gh auth login` inside container, persists via `claude-code-root`.
  - `GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN`, `AWS_*` env vars forwarded when set (overrides the above).
- **Arch-aware installs**: `dpkg --print-architecture` drives `glab` deb choice; `uname -m` drives AWS v2 installer URL. Works on Apple Silicon and Intel hosts.
- **Keep `--cap-drop ALL` and `no-new-privileges`**: CLI tools don't need capabilities.

## Risks / Trade-offs

- Bind-mounting host cred dirs RW → container can mutate host auth (e.g., AWS SSO cache refresh). Mitigation: documented, user opts in by simply having those dirs on host.
- Concurrent containers sharing `claude-code-home` could race on `.claude.json` writes. Mitigation: document "one container at a time" for now; use separate volumes if you need parallelism.
- Breaking path change loses old `/workspace` sessions from Ctrl+A. Mitigation: acceptable — setup is new, minimal history.
- glab version pinned-at-build-time via GitLab API call in Dockerfile. Rebuild picks up latest.

## Migration Plan

1. Rebuild image: `docker build -t claude-code:local ~/claude-docker`.
2. First launch: `gh auth login` inside container once (Keychain caveat).
3. Existing `claude-code-root` / `claude-code-home` volumes kept as-is.

