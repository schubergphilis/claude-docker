## Why

Every automated tool shares one soak window: 7 days. For `claude-code` that
window no longer matches how the tool is used. Claude Code ships almost daily,
and most of its users take each release within hours of it coming out. A week-old
pin puts the image several releases behind the version most of the ecosystem is
already running, and the extra days add little safety: a broken or malicious
release of a tool with that many daily installs gets noticed and pulled within
the first day. The co-maintainers agreed to lower the window for `claude-code`
to 24 hours. Every other tool keeps 7 days.

## What Changes

- Each automated tool carries its own default soak window in `update_pins.py`.
  `claude-code` gets 1 day. Every other tool keeps `DEFAULT_SOAK_DAYS` (7).
- `--soak DAYS` becomes an explicit override. When passed, it applies the same
  window to every tool for that run, as it does today. When omitted, each tool
  uses its own window.
- `--audit` (the CI soak gate) uses the same per-tool windows, so CI accepts a
  `claude-code` pin that is 1 day old.
- `pins-updater.yml` passes `--soak` only when the dispatch input is filled in.
  The schedule trigger runs without it and gets the per-tool windows. Passing
  its old hard-coded `7` would override the new `claude-code` window.
- The README, the Dockerfile comment, and the CI comment describe the per-tool
  windows.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `version-pin-refresh`: the `Soak-aware version resolution` requirement
  changes from one configurable window to a default window per tool, 1 day for
  `claude-code` and 7 days for the rest. An operator can still override the
  window for all tools in a single run.

## Impact

- `update_pins.py`: `Tool` gains `soak_days`, and resolution and `--audit`
  read it.
- `.github/workflows/pins-updater.yml`: `--soak` becomes optional.
- `tests/test_update_pins.py`: coverage for the per-tool default and the
  override.
- Docs: `README.md`, `Dockerfile` comments, `ci.yml` comment.
- No runtime or image change beyond `claude-code` pins moving up sooner.
