## Why

Ghostty sets `TERM=xterm-ghostty`, and `run.sh` forwards `TERM` into the container. The image's `ncurses-term` package ships Ghostty's terminfo entry, but only under the name `ghostty`: Debian's build has no `xterm-ghostty` alias. Every ncurses program in the container then fails to look up the terminal. `tput` exits with `unknown terminal "xterm-ghostty"`, `less` and other pagers fall back to a dumb terminal, and `--tmux` starts tmux against a terminal it cannot describe.

## What Changes

- Add `xterm-ghostty` to the image's terminfo database as an alias of the `ghostty` entry that `ncurses-term` already installs. Nothing is downloaded or vendored.
- Skip the alias if a future `ncurses-term` ships `xterm-ghostty` itself, and fail the build if `infocmp xterm-ghostty` does not resolve.

Not in scope: a general fallback for other terminals whose entries the image lacks. Other common emulators (`xterm-kitty`, `alacritty`, `wezterm`, `foot`) are already in `ncurses-term` under the name they set.

## Capabilities

### New Capabilities
<!-- None. -->

### Modified Capabilities
- `host-config-parity`: new requirement that a forwarded Ghostty `TERM` resolves in the container.

## Impact

- `Dockerfile`: one small `RUN` late in the build, after the heavy download layers.
- `README.md`: one sentence next to the `TERM` / `COLORTERM` note.
- No `run.sh` or `entrypoint.sh` changes.
