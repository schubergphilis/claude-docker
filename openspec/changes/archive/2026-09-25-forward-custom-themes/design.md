## Context

`run.sh` stages `agents/`, `commands/` and `skills/` through one loop: it resolves a top-level symlink, copies the tree with `cp -RL` so internal symlinks dereference, and bind-mounts the staged copy read-only. Custom themes are the same shape: a directory of JSON files that is often a symlink into a dotfiles repo.

Claude Code 2.1.x reads `~/.claude/themes/*.json` (files over 256 KB are skipped), watches the directory for changes, and has an in-session `/theme` editor that writes `<slug>.json` back into it.

## Goals / Non-Goals

**Goals:**
- A custom theme named in `settings.docker.json` applies in the container.
- A symlinked `themes/` directory works, as it does for the other directory items.

**Non-Goals:**
- Writing theme edits made in the container back to the host.
- Forwarding `output-styles/`, `keybindings.json` or other items with the same gap.

## Decisions

### Decision: Reuse the existing item loop

Add `themes` to `for item in agents commands skills; do`. The loop already does the symlink resolution and staging this needs, and a second code path for the same shape would drift.

### Decision: Mount read-only, not seed-copy

`settings.json` is seed-copied because Claude Code saves it by renaming a tmp file over it, and rename over a mountpoint fails with `EBUSY` on every in-session settings change. Themes differ in how often they are written: selecting a theme writes `settings.json`, not `themes/`. Only saving a theme from the `/theme` editor writes into `themes/`, and that is rare.

A read-only mount keeps `themes/` consistent with `agents/`, `skills/` and `commands/`: the host copy is the source of truth, and the container never diverges from it. The cost is that saving a theme from the in-container editor fails (Claude Code reports "theme save failed"). Theme editing happens on the host.

Alternative considered: seed-copy `themes/` into the container on each start, like `settings.json`. Rejected: edits would appear to save, then be silently discarded on the next start. That is worse than a visible failure, and it adds entrypoint code for a rare path.

### Decision: Forward `COLORTERM` as part of this change

`run.sh` forwards `TERM` but not `COLORTERM`. Claude Code then renders in 256 colours inside the container, and custom theme colours are rounded to the nearest palette entry (for example `#c17a23` renders as xterm colour 173). A theme is the feature most affected, so the fix belongs with it. `-e COLORTERM` without a value passes the host variable through only when it is set, the same as `-e TERM`.

## Risks / Trade-offs

- [User edits a theme in the container and the save fails] → Documented in the README. The theme can be edited on the host and picked up on the next start.
- [Theme files are staged per session] → The directory is small (a few KB of JSON), so the extra `cp -RL` is negligible.

## Migration Plan

None. Users who have `~/.claude/themes/` get it forwarded on their next run; users without it see no change.
