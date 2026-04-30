## Context

`run.sh` mounts host config items into the container so the environment feels
consistent with the user's host Claude Code setup. The items are staged through
a temp directory (to dereference internal symlinks via `cp -RL`) and then
bind-mounted read-only. Two bugs in that pipeline and the hardcoded config path
all surfaced together when a user tried to point the container at a second
profile directory.

## Goals / Non-Goals

**Goals:**
- Let users specify an alternate config directory via flag or env var.
- Both levels of symlink resolution work: the directory itself being a symlink,
  and individual files inside the directory being symlinks.
- Staging mounts are visible inside the container on macOS with Colima and
  Docker Desktop.

**Non-Goals:**
- Native profile management (Claude Code does not support this; `--claude-dir`
  is a workaround, not a feature of Claude Code itself).
- Automatically forwarding the host `settings.json` — users who want settings
  in the container should maintain `settings.docker.json` explicitly. Automatic
  forwarding would cause silent drift between host and container behaviour.

## Decisions

### Decision: `--claude-dir=PATH` with `=` syntax, not a two-token flag

The existing arg-parsing loop iterates `"$@"` with a `case` statement and no
lookahead. Supporting `--claude-dir PATH` (space-separated) would require
restructuring the loop. The `=`-syntax (`--claude-dir=PATH`) is parsed cleanly
with `${arg#--claude-dir=}` and is consistent with tools like `git`. An env var
(`CLAUDE_DOCKER_CONFIG_DIR`) is also provided for shell aliases and wrappers
that prefer not to embed the flag.

### Decision: Tilde-expand `CLAUDE_DOCKER_CONFIG_DIR` after argument parsing

When the value comes from the flag, the user's shell expands `~` before the
script sees it. When it comes from an env var, it does not. A `case`-based
expansion (`case "$CLAUDE_CONFIG_DIR" in "~"*) ...`) normalises both paths
without requiring `eval` or `realpath`.

### Decision: Resolve only the top-level directory symlink, then `cp -RL` for internals

Two levels of symlink need handling:

1. The directory itself (e.g. `~/.claude-anthropic/commands -> ~/claude-config/commands`)
   — resolved with a `while [ -L ]` / `readlink` loop before the `cp`.
2. Items inside the directory (e.g. `skills/create-team -> ~/git/repo/skill/`)
   — resolved by `cp -RL`, which dereferences all symlinks in the tree.

Mounting the resolved real path directly (without `cp -RL`) was considered as
a simpler alternative. It was rejected because absolute symlinks inside the
directory would be dangling in the container; `cp -RL` makes them regular files.

### Decision: Stage in `$HOME`, not `$TMPDIR` or `/tmp`

Colima's default mount config (verified against `colima.yaml` and confirmed by
inspecting `mount` inside a running Colima VM) shares exactly one macOS host
path into its Linux VM: `$HOME`, mounted via virtiofs at the same path
(`/Users/$USER`). Neither `$TMPDIR` (`/var/folders/…`) nor `/tmp` is shared.

A bind-mount sourced from outside `$HOME` is accepted by `docker run` without
error, but the bind-mount target ends up referencing the *VM's* filesystem
at that path (which is empty) rather than the macOS host. The container
shows an empty mountpoint with no obvious indication of why — a silent
failure that is hard to diagnose. An earlier iteration of this change used
`/tmp/claude-docker-host.XXXXXX` and worked under Docker Desktop (which
shares `/private`, including `/private/tmp`) but failed under Colima for
exactly this reason.

Staging under `$HOME/.cache/claude-docker/host.XXXXXX` works for both
runtimes: `$HOME` is always shared. The `.cache/` subdirectory follows the
XDG basedir convention so the parent dir survives across runs and only the
`host.XXXXXX` subdirectory is removed by the EXIT trap.

### Decision: No `--forward-settings` flag

An earlier draft of this change included `--forward-settings` to copy the
profile's `settings.json` into the container. This was dropped because
`settings.docker.json` already serves that purpose without a flag — the user
creates it once and it is automatically picked up. An opt-in flag would add
complexity (one more flag, one more DOCKER_FLAGS tag in the statusline) while
providing no advantage over the existing file-based mechanism.

### Decision: Single files (`CLAUDE.md`, `statusline-command.sh`, `settings.docker.json`) are mounted directly

For single files, Docker resolves host-side symlinks in bind-mounts
automatically. Staging them (copying to a stage dir then mounting the copy)
adds I/O with no benefit. Only directory trees need staging to dereference
internal symlinks that would otherwise be dangling in the container.

The generated statusline wrapper script is the one exception: it is created in
the stage rather than copied from the host, so it still uses the `$HOME`
stage. The original `statusline-command.sh` is mounted directly from the
config dir.

## Risks / Trade-offs

- [Absolute symlinks inside `agents/`/`commands/`/`skills/`] → `cp -RL`
  dereferences them, so they become regular files in the container. The trade-off
  is that edits made to staged copies are not reflected back to the originals
  (they are read-only mounts anyway). Acceptable for a read-only bind-mount.
- [Crash leaves orphaned stage dirs in `$HOME/.cache/claude-docker/`] → The
  `EXIT` trap removes the stage on normal exit. A crash could leave orphaned
  `host.XXXXXX` subdirectories under `$HOME/.cache/claude-docker/`. Cheap to
  clean up manually; same risk profile as any temp-dir approach.
- [Users expecting `settings.json` to auto-forward] → Documented in `--help`
  output and the spec. `settings.docker.json` is the explicit opt-in.
