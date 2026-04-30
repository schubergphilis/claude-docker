## Why

Claude Code does not natively support multiple profiles, but users can work
around this by pointing it at different config directories — for example,
`~/.claude` for API key usage and `~/.claude-anthropic` for a Claude Enterprise
subscription, each with its own settings, commands, and agents. `run.sh`
currently hardcodes `~/.claude` for every config item it mounts, so there is
no way to tell the container which profile's config to load.

Two bugs in the existing mounting logic were also discovered during this work:

1. **Top-level directory symlinks were silently skipped.** `cp -RL` does not
   reliably dereference a directory that is itself a symlink (e.g.
   `~/.claude/commands -> ~/claude-config/commands`). The staged copy was empty
   and the container saw no commands.

2. **The staging directory was invisible inside the container.** `mktemp -d -t`
   places the stage under `$TMPDIR`, which on macOS resolves to
   `/var/folders/…`. Colima and Docker Desktop (depending on file-sharing
   configuration) do not mount `/var/folders` into the Linux VM, so bind-mounts
   from the stage appeared as empty directories in the container.

## What Changes

- Add `--claude-dir=PATH` flag and `CLAUDE_DOCKER_CONFIG_DIR` env var so all
  host config items (`agents/`, `commands/`, `skills/`, `CLAUDE.md`,
  `statusline-command.sh`, `settings.docker.json`) are read from a
  user-specified directory instead of `~/.claude`.
- Fix top-level directory symlink resolution: resolve the symlink chain with
  `readlink` before staging so `cp -RL` always receives a real directory path.
- Move the staging directory from `$TMPDIR` to `/tmp` (`/private/tmp` on macOS),
  which is shared into the Linux VM by both Docker Desktop and Colima.
- Update `--help` output to document `--claude-dir`, `CLAUDE_DOCKER_CONFIG_DIR`,
  and the `settings.docker.json` → `settings.json` mounting behaviour.

## Capabilities

### Modified Capabilities
- `host-config-parity`: extended with a configurable config directory and
  corrected symlink + staging behaviour. No new capability spec is needed.
