## Context

`ncurses-term` 6.6+20251231 installs `/usr/share/terminfo/g/ghostty` ("ghostty|Ghostty terminal emulator"), the ncurses maintainers' entry for Ghostty. Ghostty itself sets `TERM=xterm-ghostty` and ships its own entry, named `xterm-ghostty|ghostty|Ghostty`, inside the app bundle. That entry is not available in the container.

## Decisions

### Decision: Alias to the ncurses entry, not vendor Ghostty's entry

Link `x/xterm-ghostty` to `g/ghostty` in `/usr/share/terminfo`. terminfo lookups go by file name, so the link makes `xterm-ghostty` resolve to the ncurses entry.

The two entries agree on the standard capabilities. They differ mainly in extensions: Ghostty's own entry adds `Tc`, `setrgbf`/`setrgbb`, `Sync`, `Setulc` and `fullkbd`, while the ncurses entry leaves those out. Claude Code does not read these; it picks truecolor from `COLORTERM`, which `run.sh` forwards.

Alternative considered: commit Ghostty's own entry (`infocmp -x xterm-ghostty` output) and compile it with `tic -x` at build time. That gives exact capabilities, but it means reviewing and refreshing a vendored file produced on a maintainer's machine, while the alias uses bytes from the signed Ubuntu package. Rejected for now. Revisit if tmux inside the container needs one of the extensions.

### Decision: Guard the alias and assert the lookup

A later `ncurses-term` may ship `xterm-ghostty` itself. The build creates the link only when the name is absent, then runs `infocmp xterm-ghostty`, so an unexpected layout fails the build instead of shipping an image that silently lacks the entry.

### Decision: A late, separate layer

The `RUN` sits next to the tmux configuration, after the npm and binary-download layers, so it does not invalidate them. It depends only on `ncurses-term` from the first apt layer.

## Risks / Trade-offs

- [ncurses entry lacks Ghostty's extensions] → Accepted. Programs that need an extension can set their own override. Claude Code is unaffected because it uses `COLORTERM`.

## Migration Plan

None. The next image build resolves `xterm-ghostty`.
