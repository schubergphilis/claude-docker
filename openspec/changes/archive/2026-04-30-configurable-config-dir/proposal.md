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
   `/var/folders/…`. Colima's default mount config exposes only `$HOME`
   (`/Users/$USER`) to the Linux VM — neither `$TMPDIR` nor `/tmp` is shared.
   A bind-mount sourced from outside `$HOME` starts without error but
   silently yields an empty mountpoint inside the container. Docker Desktop
   shares more host paths by default, which masked the bug for that runtime.

## What Changes

- Add `--claude-dir=PATH` flag and `CLAUDE_DOCKER_CONFIG_DIR` env var so all
  host config items (`agents/`, `commands/`, `skills/`, `CLAUDE.md`,
  `statusline-command.sh`, `settings.docker.json`) are read from a
  user-specified directory instead of `~/.claude`.
- Fix top-level directory symlink resolution: resolve the symlink chain with
  `readlink` before staging so `cp -RL` always receives a real directory path.
- Move the staging directory from `$TMPDIR` to `$HOME/.cache/claude-docker/`,
  which is the only host path Colima shares into its Linux VM by default
  (Docker Desktop also shares it).
- Update `--help` output to document `--claude-dir`, `CLAUDE_DOCKER_CONFIG_DIR`,
  and the `settings.docker.json` → `settings.json` mounting behaviour.

## Capabilities

### Modified Capabilities
- `host-config-parity`: extended with a configurable config directory and
  corrected symlink + staging behaviour. No new capability spec is needed.
