## Why

`claude-docker` currently has no `-h`/`--help` flag. The only discovery paths are reading `run.sh` or the README, and the inline comments at the top of `run.sh` drift out of sync as flags are added. Users hitting the script cold have no way to enumerate available flags from the terminal.

## What Changes

- Add `-h` and `--help` flags to `run.sh`. When present (anywhere before the `--` separator), print usage and exit 0 without running Docker.
- Help output includes per-flag explanations for every wrapper flag: `--yolo`, `--ephemeral`, `--ro`, `--aws`, `--gh`, `--glab`, `--iterm`, `--tmux`, and the `--` separator; plus the `CLAUDE_DOCKER_TMUX` env var and positional workspace args.
- Flags after `--` are NOT interpreted — `claude-docker -- --help` still forwards `--help` to `claude` unchanged.

## Capabilities

### New Capabilities

- `cli-help`: `claude-docker -h`/`--help` prints self-documenting per-flag usage to stdout and exits 0, covering every wrapper flag, the `--` separator, positional workspaces, and `CLAUDE_DOCKER_TMUX`.

### Modified Capabilities

<!-- None. Help output is additive and does not change existing flag semantics. -->

## Impact

- Files: `run.sh` (flag parsing + help printer), `README.md` (mention `--help` as the canonical flag reference).
- No Docker rebuild required — the wrapper script runs on the host.
- No breaking changes; existing invocations are unaffected.
