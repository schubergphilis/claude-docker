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

### Decision: Stage in `/tmp`, not `$TMPDIR`

On macOS, `mktemp -d -t …` creates under `$TMPDIR` which resolves to
`/var/folders/…`. Colima (and Docker Desktop with certain file-sharing
configurations) does not mount `/var/folders` into the Linux VM. Bind-mounts
from that path are accepted by Docker without error but appear as empty
directories in the container — a silent failure that is hard to diagnose.

`/tmp` on macOS is a symlink to `/private/tmp`. `/private` is always in both
Docker Desktop's and Colima's default mount list. Using an explicit
`/tmp/claude-docker-host.XXXXXX` template (no `-t` flag) ensures the stage
lands in `/private/tmp` regardless of `$TMPDIR`.

### Decision: No `--forward-settings` flag

An earlier draft of this change included `--forward-settings` to copy the
profile's `settings.json` into the container. This was dropped because
`settings.docker.json` already serves that purpose without a flag — the user
creates it once and it is automatically picked up. An opt-in flag would add
complexity (one more flag, one more DOCKER_FLAGS tag in the statusline) while
providing no advantage over the existing file-based mechanism.

### Decision: Single files (`CLAUDE.md`, `statusline-command.sh`, `settings.docker.json`) are mounted directly

For single files, Docker resolves host-side symlinks in bind-mounts
automatically. Staging them (copying to `/tmp` then mounting the copy) adds
I/O with no benefit. Only directory trees need staging to dereference internal
symlinks that would otherwise be dangling in the container.

The generated statusline wrapper script is the one exception: it is created in
the stage rather than copied from the host, so it still uses the `/tmp` stage.
The original `statusline-command.sh` is mounted directly from the config dir.

## Risks / Trade-offs

- [Absolute symlinks inside `agents/`/`commands/`/`skills/`] → `cp -RL`
  dereferences them, so they become regular files in the container. The trade-off
  is that edits made to staged copies are not reflected back to the originals
  (they are read-only mounts anyway). Acceptable for a read-only bind-mount.
- [`/tmp` cleaned by the OS mid-session] → The `EXIT` trap removes the stage on
  normal exit. A crash could leave orphaned `/tmp/claude-docker-host.*`
  directories. Identical risk to the prior `$TMPDIR`-based approach.
- [Users expecting `settings.json` to auto-forward] → Documented in `--help`
  output and the spec. `settings.docker.json` is the explicit opt-in.
