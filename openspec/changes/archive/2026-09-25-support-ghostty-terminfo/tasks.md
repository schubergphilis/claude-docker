## 1. Implementation

- [x] 1.1 Add a `RUN` after the tmux configuration that links `/usr/share/terminfo/x/xterm-ghostty` to `../g/ghostty` when absent, then runs `infocmp xterm-ghostty`.

## 2. Documentation

- [x] 2.1 Mention Ghostty's `xterm-ghostty` next to the README's `TERM` / `COLORTERM` note.

## 3. Verification

- [x] 3.1 `docker build -t claude-code:local .` succeeds.
- [x] 3.2 With `TERM=xterm-ghostty`, `tput colors` and `infocmp xterm-ghostty` succeed in the container.
- [x] 3.3 With `TERM=xterm-ghostty COLORTERM=truecolor`, tmux in the container starts and reports the RGB feature.
- [x] 3.4 hadolint passes.

## 4. Archive readiness

- [x] 4.1 `openspec validate support-ghostty-terminfo --strict` reports no errors.
