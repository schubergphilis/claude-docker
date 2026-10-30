# Tasks

- [x] 1.1 `parse_args`: accept repeatable `--ro=PATH` (expand leading `~/`, reject empty) and record a per-workspace read-only marker in a parallel array; `$PWD` stays the default only when no workspace is given. Verify with bats.
- [x] 1.2 `build_workspace_mounts`: append `:ro` per workspace when `--ro` is set or that workspace was passed as `--ro=PATH`. Verify with bats: mixed mount args, `--ro=.`.
- [x] 1.3 `build_workspace_mounts`: refuse the same path twice, and the same directory through a symlink in two modes; warn when a read-only workspace is inside a writable one. Compare symlink-resolved paths. Verify with bats.
- [x] 1.4 `build_flags_env`: tag `ro` when every workspace is read-only, `ro-partial` when some are. Verify with bats.
- [x] 1.5 Help text: describe `--ro=PATH`, that it counts as a workspace, and that it does not isolate untrusted content.
- [x] 1.6 Docs: `docs/usage.md` (session flags, overlaps, untrusted content, statusline tag list), `docs/security.md`, `SECURITY.md`.
- [x] 1.7 Run the bats suite and shellcheck; `openspec validate ro-per-workspace --strict`.
