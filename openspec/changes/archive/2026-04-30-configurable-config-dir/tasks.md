## 1. Flag and env var

- [x] 1.1 Add `CLAUDE_CONFIG_DIR="${CLAUDE_DOCKER_CONFIG_DIR:-$HOME/.claude}"` variable initialisation.
- [x] 1.2 Add `--claude-dir=*` case branch that sets `CLAUDE_CONFIG_DIR`.
- [x] 1.3 Add tilde-expansion for `CLAUDE_CONFIG_DIR` after argument parsing.

## 2. Symlink and staging fixes

- [x] 2.1 Replace `[ -d "$HOME/.claude/$item" ]` + `cp -RL` with a `while [ -L ]` symlink-resolution loop, then `cp -RL` from the resolved real path.
- [x] 2.2 Change `mktemp -d -t claude-docker-host.XXXXXX` to `mktemp -d "$HOME/.cache/claude-docker/host.XXXXXX"` (with `mkdir -p` of the parent) so the stage lands inside `$HOME`, the only host path Colima shares into its VM by default.
- [x] 2.3 Update the `EXIT` trap pattern from `*/claude-docker-host.*` to `"$HOME/.cache/claude-docker/host."*`.
- [x] 2.4 Replace all remaining `$HOME/.claude/` references in the staging section with `$CLAUDE_CONFIG_DIR/`.

## 3. Single-file mounts

- [x] 3.1 Mount `CLAUDE.md` directly (no staging): `-v "$CLAUDE_CONFIG_DIR/CLAUDE.md"`.
- [x] 3.2 Mount `statusline-command.sh` original directly; keep only the generated wrapper in the stage.
- [x] 3.3 Mount `settings.docker.json` directly using `$CLAUDE_CONFIG_DIR`.

## 4. Help output

- [x] 4.1 Add `--claude-dir=PATH` to the Wrapper flags section of `print_help`.
- [x] 4.2 Add `CLAUDE_DOCKER_CONFIG_DIR` to the Environment section of `print_help`.
- [x] 4.3 Add a Settings note explaining `settings.docker.json` behaviour.

## 5. Spec updates

- [x] 5.1 Update `host-config-parity` spec: add configurable config dir requirement and scenarios, update symlink resolution requirement to cover both levels, update settings requirement to remove `--forward-settings` references.
- [x] 5.2 Update `cli-help` spec: add `--claude-dir` and `CLAUDE_DOCKER_CONFIG_DIR` to the enumerated flags and scenario.

## 6. Verification

- [x] 6.1 `claude-docker ~/repo` with default `~/.claude` — agents/commands/skills mount correctly.
- [x] 6.2 `claude-docker --claude-dir=~/.claude-anthropic ~/repo` — config items load from the alternate dir.
- [x] 6.3 Config dir where a subdirectory (e.g. `commands/`) is itself a symlink — files appear in the container.
- [x] 6.4 Config dir where items inside a directory are symlinks — files resolve (not dangling) in the container.
- [x] 6.5 `settings.docker.json` present in the config dir — mounted as `settings.json` in the container.
- [x] 6.6 Verified on Colima (the runtime where the staging bug was reproduced; Colima only shares `$HOME` by default, so any non-`$HOME` stage path silently fails).
