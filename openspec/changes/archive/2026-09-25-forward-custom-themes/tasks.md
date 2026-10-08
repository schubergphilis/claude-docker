## 1. Implementation

- [x] 1.1 Add `themes` to the item loop in `run.sh` (`for item in agents commands skills themes; do`).
- [x] 1.2 Forward `COLORTERM` next to `TERM` in `run.sh` (`ENV_ARGS=(-e TERM -e COLORTERM)`).
- [x] 1.3 List `themes` in the `--claude-dir` entry of `run.sh --help`.

## 2. Documentation

- [x] 2.1 Add a `~/.claude/themes/` row to the README "Host config parity" table.
- [x] 2.2 Add themes to the `--claude-dir` paragraph's item list.
- [x] 2.3 Note in the README that the themes mount is read-only, so saving a theme from the in-container `/theme` editor fails and themes are edited on the host.

## 3. Verification

- [x] 3.1 With `~/.claude/themes` a symlink to a real directory, `run.sh` stages the theme files and the container sees them at `/root/.claude/themes/` as regular files, mounted read-only.
- [x] 3.2 With `settings.docker.json` naming `custom:<slug>` for a forwarded theme, the theme applies in the container.
- [x] 3.3 With `COLORTERM=truecolor` on the host, the container sees it and Claude Code emits 24-bit colour for the theme.
- [x] 3.4 `shellcheck --severity=warning run.sh` passes.

## 4. Archive readiness

- [x] 4.1 `openspec validate forward-custom-themes --strict` reports no errors.
