## ADDED Requirements

### Requirement: Ghostty terminal type resolves in the container

The image SHALL resolve `TERM=xterm-ghostty`, the value Ghostty sets and `run.sh` forwards, to a terminfo entry. The entry SHALL come from the image's `ncurses-term` package: when that package does not provide `xterm-ghostty` itself, the build SHALL alias it to the package's `ghostty` entry. The build SHALL fail if `infocmp xterm-ghostty` does not resolve.

#### Scenario: ncurses programs recognise Ghostty

- **GIVEN** the host terminal is Ghostty, with `TERM=xterm-ghostty`
- **WHEN** user runs `claude-docker` and, inside the container, `tput colors`
- **THEN** `tput` succeeds instead of failing with `unknown terminal "xterm-ghostty"`

#### Scenario: Entry comes from the image's package

- **WHEN** a reader inspects how the image provides `xterm-ghostty`
- **THEN** it is either shipped by `ncurses-term` or a link to that package's `ghostty` entry
- **AND** no terminfo source is downloaded or vendored into the repository
