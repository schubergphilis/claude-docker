## Why

Claude Code loads custom themes from `~/.claude/themes/*.json` and selects one with `"theme": "custom:<slug>"` in `settings.json`. `run.sh` forwards `agents/`, `skills/`, `commands/`, `CLAUDE.md` and the statusline script, but not `themes/`. A `settings.docker.json` that names a custom theme therefore points at a theme the container cannot see, and the session falls back to a built-in theme. That breaks the "container feels like the host" goal of `host-config-parity`.

## What Changes

- Add `themes/` to the host config items `run.sh` stages and bind-mounts read-only at `/root/.claude/themes/`. It reuses the existing item loop, so a symlinked `themes/` directory and symlinks inside it resolve the same way they already do for `agents/`, `skills/` and `commands/`.
- `--claude-dir` / `CLAUDE_DOCKER_CONFIG_DIR` cover `themes/` like every other item.
- Forward `COLORTERM` alongside `TERM`. Without it Claude Code falls back to 256 colours in the container, so a custom theme renders with rounded colours and looks different from the host.
- Document `themes/` in the README "Host config parity" table, the `--claude-dir` paragraph, and `run.sh --help`.

Not in scope: `output-styles/`, `keybindings.json`, or other user-level config that has the same gap. Those are separate proposals.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `host-config-parity`: the "Bind-mount host Claude config items" requirement lists `themes/` among the forwarded items, with a scenario for a symlinked themes directory. A new "Forward terminal colour capability" requirement covers `COLORTERM`.

## Impact

- `run.sh`: one more name in the item loop, `-e COLORTERM` next to `-e TERM`, and the `--claude-dir` help text.
- `README.md`: parity table row, `--claude-dir` paragraph.
- In-session theme *editing* (the `/theme` editor saving `<slug>.json`) fails against the read-only mount; selecting an existing custom theme works. See `design.md`.
- No new flags, volumes, or credential surface. `COLORTERM` carries no secrets.
