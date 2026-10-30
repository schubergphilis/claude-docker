# host-config-parity

## Purpose

Make the container feel like the user's host Claude Code: same statusline, skills, agents, commands, global preferences, and a container-specific `settings.docker.json` when the user provides one — without copying macOS-only configuration or host-filesystem hooks that would misfire inside the Linux container.

The host config directory defaults to `~/.claude` but is configurable via `--claude-dir=PATH` or the `CLAUDE_DOCKER_CONFIG_DIR` env var. This supports users who maintain multiple Claude profiles (e.g. one for API key usage, one for a Claude Enterprise subscription), each with its own config directory, OAuth token, and conversation history.

## Requirements

### Requirement: Configurable host config directory

`run.sh` SHALL read all host config items from a single base directory. The base directory defaults to `~/.claude` and MAY be overridden with `--claude-dir=PATH` (flag) or `CLAUDE_DOCKER_CONFIG_DIR` (env var). When both are provided, the flag takes precedence.

#### Scenario: Alternate config dir is used

- **GIVEN** `~/.claude-anthropic/` contains a `commands/` directory with custom slash commands
- **WHEN** user runs `claude-docker --claude-dir=~/.claude-anthropic ~/repo`
- **THEN** `/root/.claude/commands/` in the container contains the commands from `~/.claude-anthropic/commands/`

#### Scenario: Env var sets the config dir

- **GIVEN** `CLAUDE_DOCKER_CONFIG_DIR=~/.claude-anthropic` is set in the environment
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** config items are loaded from `~/.claude-anthropic/` as if `--claude-dir=~/.claude-anthropic` had been passed

### Requirement: Bind-mount host Claude config items

`run.sh` SHALL copy the following host items (when present) into the stage directory and bind-mount the copies read-only into the container at the equivalent `/root/.claude/` path: `agents/`, `skills/`, `commands/`, `themes/`, `CLAUDE.md`, `statusline-command.sh` (mounted as `statusline-command.original.sh` behind the wrapper). No host path of these items SHALL be bind-mounted directly. Symlinks are handled at three levels:

1. **Item**: `$CLAUDE_CONFIG_DIR/<item>` may be one symlink. Its target, with trailing slashes removed, is used when it exists, does not end in `.` or `..`, and is not itself a symlink; otherwise the item is skipped with a warning.
2. **Entry**: each entry directly inside `agents/`, `skills/`, `commands/` or `themes/` may likewise be one symlink, to a directory or a file, which is copied in its place. When the item itself is a symlink, its entries SHALL get no hop of their own and SHALL be treated as rule 3 treats links inside a copied entry: the item's target may be a directory a session can write, so a link there may not be the user's.
3. **Inside a copied entry**: no symlink SHALL be followed. A symlink SHALL be kept as a symlink only when its target is relative, consists of leading `../` components (no more than its depth below the entry) followed by plain names, and so resolves inside the copied entry; any other symlink SHALL be skipped with a warning. A `.git` entry inside a copied entry SHALL NOT be copied.

Every file and directory SHALL be read without following a symlink that was swapped in while `run.sh` reads it: each directory is entered and checked to be the inode `lstat` names, and each file is opened and checked to be the inode `lstat` names. A session can write any workspace, and link targets often live in a repo the user also opens as one, so following a link there could copy another host file into the container.

The stage directory MUST reside under `$HOME` (e.g. `$HOME/.cache/claude-docker/host.XXXXXX`). Colima's default mount config exposes only `$HOME` (`/Users/$USER`) to its Linux VM — `/tmp` and `$TMPDIR` are NOT shared. A bind-mount sourced from outside `$HOME` starts without error but silently yields an empty mountpoint inside the container under Colima. Docker Desktop also shares `$HOME` (under `/Users`), so `$HOME` is the one stage location that works on both runtimes.

Host `hooks/` and the `hooks` settings key are intentionally NOT carried over — host hooks exist to protect the host filesystem, which Docker already isolates.

`themes/` is mounted read-only like the other directory items, not seed-copied like `settings.json`: selecting a theme writes `settings.json`, which is already writable, while saving a theme from Claude Code's in-session theme editor writes into `themes/` and SHALL fail rather than silently diverge from the host copy. Themes are edited on the host.

#### Scenario: Skills via symlinks resolve in container

- **GIVEN** `~/.claude/skills/create-team` is a symlink to `~/repos/shared-config/skills/create-team`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/skills/create-team/` in the container contains the skill files (not a dangling symlink)

#### Scenario: Top-level directory symlink resolves in container

- **GIVEN** `~/.claude-anthropic/commands` is a symlink to `~/claude-config/commands`
- **WHEN** user runs `claude-docker --claude-dir=~/.claude-anthropic ~/repo`
- **THEN** `/root/.claude/commands/` in the container contains the files from `~/claude-config/commands/`

#### Scenario: Custom theme via symlinked themes dir resolves in container

- **GIVEN** `~/.claude/themes` is a symlink to a real directory containing `my-theme.json`
- **AND** `~/.claude/settings.docker.json` sets `"theme": "custom:my-theme"`
- **WHEN** user runs `claude-docker` and `claude` starts
- **THEN** `/root/.claude/themes/my-theme.json` in the container is a regular file with the host theme's contents
- **AND** the custom theme applies in the session

#### Scenario: Statusline renders in container

- **GIVEN** host has `~/.claude/statusline-command.sh`
- **WHEN** user runs `claude-docker` and `claude` starts
- **THEN** the statusline renders using a copy of the host-provided script

#### Scenario: Relative links inside a linked skill are kept

- **GIVEN** `~/.claude/skills/foo` links to `~/repos/x/skills/foo`, which contains `entry -> lib/run.sh` and `lib/up -> ../SKILL.md`
- **WHEN** user runs `claude-docker`
- **THEN** both links exist in `/root/.claude/skills/foo/` and resolve to the copied files

#### Scenario: A link planted inside a linked skill is not followed

- **GIVEN** `~/.claude/skills/foo` links to `~/repos/x/skills/foo`, and a session has added `key -> ~/.ssh/id_ed25519`, `rel -> ../../../.ssh/id_ed25519` and `lib/root -> ../..` there
- **WHEN** user runs `claude-docker`
- **THEN** none of those links, nor the key's contents, appear in the stage directory or the container
- **AND** `run.sh` prints a `claude-docker: skipping` warning naming each skipped link

#### Scenario: A link planted in a linked item's target is not followed

- **GIVEN** `~/.claude/skills` is a symlink to `~/dotfiles/claude/skills`, and `~/dotfiles` is open as a workspace
- **AND** a session has created `~/dotfiles/claude/skills/x` as a symlink to `~/.ssh`
- **WHEN** user next runs `claude-docker`
- **THEN** `x` is skipped with a warning
- **AND** nothing from `~/.ssh` is copied into the container

#### Scenario: A link chain is refused

- **GIVEN** `~/.claude/skills` is a symlink to `~/hop`, itself a symlink to a directory; or `~/.claude/skills/foo` links to a path (with or without a trailing slash) a session has replaced with a symlink; or `~/.claude/CLAUDE.md` links to a file that is a symlink
- **WHEN** user runs `claude-docker`
- **THEN** that item or entry is not copied or mounted, and `run.sh` prints a `claude-docker: skipping` warning

### Requirement: Container-specific settings file

When `$CLAUDE_CONFIG_DIR/settings.docker.json` exists, `run.sh` SHALL copy it into the stage directory under the same symlink rules as `CLAUDE.md` (at most one symlink, to a regular file) and bind-mount the copy read-only at the seed path `/run/claude-docker/settings.json`, and `entrypoint.sh` SHALL copy the seed to `/root/.claude/settings.json` at container start. The container-side `settings.json` MUST be a regular file, not a mountpoint: Claude Code persists settings by renaming a tmp file over `settings.json`, and `rename()` over a mountpoint fails with `EBUSY`, which would break every in-session settings change. In-session changes therefore save successfully, last for that container run, and are overwritten from the host file on the next start; nothing is ever written back to the host. When absent, no settings file is seeded and any `settings.json` already in the persistent home volume is left as-is. The regular `settings.json` is never forwarded automatically — users maintain `settings.docker.json` explicitly to prevent silent drift between host and container behaviour.

#### Scenario: Container uses dedicated settings file

- **GIVEN** `~/.claude/settings.docker.json` contains `{"effortLevel": "high"}`
- **WHEN** user runs `claude-docker`
- **THEN** `/root/.claude/settings.json` in the container is a writable copy of that file

#### Scenario: In-session settings change saves without EBUSY

- **GIVEN** the container started with a seeded `/root/.claude/settings.json`
- **WHEN** Claude Code renames a tmp file over `/root/.claude/settings.json` (e.g. the user changes effort or model in-session)
- **THEN** the rename succeeds and the change applies for the rest of the run
- **AND** the host `settings.docker.json` is unchanged
- **AND** the next container start re-seeds `settings.json` from the host file

#### Scenario: Alternate config dir with settings.docker.json

- **GIVEN** `~/.claude-anthropic/settings.docker.json` exists
- **WHEN** user runs `claude-docker --claude-dir=~/.claude-anthropic ~/repo`
- **THEN** `/root/.claude/settings.json` in the container is a copy of `~/.claude-anthropic/settings.docker.json`

#### Scenario: No settings file

- **GIVEN** `settings.docker.json` does not exist in the config dir
- **WHEN** user runs `claude-docker`
- **THEN** the container starts without a host-derived `settings.json` seed and Claude uses defaults (or whatever a previous run persisted in the home volume)

### Requirement: IS_SANDBOX env for root + dangerous-skip-permissions

The image SHALL set `IS_SANDBOX=1` so `claude --dangerously-skip-permissions` (and the `--yolo` shortcut) work in the legacy `HOST_UID=0` fall-through path where the entrypoint does not drop privileges. In steady state the entrypoint drops the container to the host UID before exec'ing claude, so the root-user check does not trigger and `IS_SANDBOX=1` is not load-bearing. The container narrows blast radius compared to using the flag on the host, but is not a full sandbox — see the project's threat-model documentation.

#### Scenario: YOLO works in container

- **WHEN** user runs `claude-docker --yolo`
- **THEN** `claude --dangerously-skip-permissions` launches without the root refusal error

### Requirement: Forward terminal colour capability

`run.sh` SHALL forward the host's `COLORTERM` to the container alongside `TERM`, when it is set. Claude Code picks truecolor or 256-colour output from these variables; without `COLORTERM` it falls back to 256 colours in the container and renders custom theme colours rounded to the nearest palette entry, so a theme looks different from the host. When `COLORTERM` is unset on the host it SHALL stay unset in the container.

#### Scenario: Truecolor terminal renders exact theme colours

- **GIVEN** the host terminal sets `COLORTERM=truecolor`
- **WHEN** user runs `claude-docker`
- **THEN** `COLORTERM=truecolor` is set in the container
- **AND** Claude Code renders custom theme colours as 24-bit escape sequences, as it does on the host

### Requirement: Ghostty terminal type resolves in the container

The image SHALL resolve `TERM=xterm-ghostty`, the value Ghostty sets and `run.sh` forwards, to a terminfo entry. The entry SHALL come from the image's `ncurses-term` package: the build SHALL alias `xterm-ghostty` to the package's `ghostty` entry. The build SHALL fail if `infocmp xterm-ghostty` does not resolve.

#### Scenario: ncurses programs recognise Ghostty

- **GIVEN** the host terminal is Ghostty, with `TERM=xterm-ghostty`
- **WHEN** user runs `claude-docker` and, inside the container, `tput colors`
- **THEN** `tput` succeeds instead of failing with `unknown terminal "xterm-ghostty"`

#### Scenario: Entry comes from the image's package

- **WHEN** a reader inspects how the image provides `xterm-ghostty`
- **THEN** it is a link to the `ghostty` entry shipped by `ncurses-term`
- **AND** no terminfo source is downloaded or vendored into the repository
