## Why

At launch, `run.sh` reads host files from places a session can write: each workspace's `.git/config`, and Claude config items whose symlinks often point into a repo the user also opens as a workspace. Today it checks for symlinks and then copies or mounts in a separate step, or follows symlinks wholesale (`cp -RL`, bind mounts of `CLAUDE.md`, the statusline script and `settings.docker.json`). A link a session plants there, or swaps in during the gap between check and copy (#211), makes the next launch copy another host file into the container.

## What Changes

- Every host file `run.sh` copies from a session-writable path is read without following a symlink anywhere in its path below a trusted root. Each directory is entered and checked to be the inode `lstat` named, and each file is opened and checked to be the inode `lstat` names, so a link swapped in at any moment fails the check. This covers the `.git/config` overlay copy and the `--glab` origin-host read.
- Host config items (`agents/`, `skills/`, `commands/`, `themes/`, `CLAUDE.md`, `statusline-command.sh`, `settings.docker.json`) are copied into the stage dir and the copies mounted. Each item, and each entry directly in a directory item, may be one symlink the user made. Its target must not be another link. Inside what those reach, a link is kept only when relative and resolving inside the copied entry; others are skipped with a warning. This replaces `cp -RL` and the direct file mounts.
- Workspaces resolve to their physical path (`pwd -P`), which is what the engine mounts anyway. A workspace that is itself a symlink is announced at start and mounted under its target's name.
- The Windows `core.autocrlf` value carried into the overlay must be `true`, `false` or `input`.

## Capabilities

- `host-config-parity`: MODIFIED *Bind-mount host Claude config items*, *Container-specific settings file*.
- `multi-workspace-mounts`: MODIFIED *Nested worktrees portable via a container-only git config overlay*; ADDED *Workspaces mount their physical path*.

## Impact

- **Behaviour change:**
  - A symlink chain (`skills -> a -> b`) for a config item or entry is no longer followed; point the link straight at the real directory.
  - Links inside a linked skill or agent that leave it are no longer copied.
  - Host edits to `CLAUDE.md` or the statusline script during a session apply from the next start.
- **Launch time:** the copy runs a few processes per file. That's about 0.1 s for 24 files and about 2.7 s for 500 (Linux).
- **Limits:**
  - A session whose workspace holds the item or entry link itself (the config dir or dotfiles opened as a workspace) can still repoint it.
  - A directory above a link target can still be redirected to a host path with the same name.
  - Both limits are stated in the threat model.
