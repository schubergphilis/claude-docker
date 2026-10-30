# Usage

[← Back to the README](../README.md)

## Container runtime

`claude-docker` runs on **docker or podman**. With no configuration it auto-detects the engine, preferring `docker` and falling back to `podman` — so a podman-only host (including Windows via `podman machine` + WSL backend, and podman-as-docker Linux setups) works with zero setup and never hits `docker: command not found`.

To force an engine, set `CLAUDE_DOCKER_RUNTIME`:

```bash
CLAUDE_DOCKER_RUNTIME=podman claude-docker ~/repo
```

The env var is the canonical mechanism: it works everywhere — scripts, CI, editor "run" integrations, and non-interactive shells all inherit it. If you want a shorter interactive spelling, an alias is optional sugar (not a substitute — an alias only resolves at an interactive prompt, so scripts and editors still need the env var):

```bash
alias claude-podman='CLAUDE_DOCKER_RUNTIME=podman claude-docker'
```

Only `docker` and `podman` are accepted; any other value is rejected before anything runs. The image build is the engine's own command — `podman build -t claude-code:local .` on a podman host, mirroring the `docker build` line in the [Quickstart](../README.md#quickstart).

**Windows:** run `claude-docker` from PowerShell (via the [`claude-docker.ps1`](../claude-docker.ps1) launcher), WSL2 or Git Bash — see [Windows](windows.md) for setup and the Git Bash specifics.

## Running claude-docker

```bash
claude-docker                             # current dir as workspace
claude-docker ~/repo-a ~/repo-b           # multi-workspace
claude-docker --yolo ~/repo               # alias for --dangerously-skip-permissions
claude-docker ~/repo -- --resume          # resume a past session (any claude flag goes after --)
```

`claude-docker --help` (or `-h`) prints every wrapper flag with a one-line explanation — the canonical reference.

Credential flags (`--aws`, `--gh`, …) are covered in [Credential opt-in](auth.md#credential-opt-in).

### Session flags

| Flag          | Effect                                                                                                                      |
| ------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `--ephemeral` | Skip the persistent named volumes. No in-container auth state, shell history, or conversation history persists across runs. |
| `--ro`        | Mount every workspace read-only. Prevents the agent from modifying your code.                                               |
| `--ro=PATH`   | Add PATH as a workspace mounted read-only; the others stay writable. Repeatable. Not isolation for untrusted repos.         |

`--ro` does **not** block credential flags or restrict network egress (only `--egress-lock` and `--egress-allowlist` do, see [API egress lock](auth.md#api-egress-lock) and [Egress allowlist](auth.md#egress-allowlist)) — for an isolated review session, combine `--ephemeral` and `--ro` and pass no credential flags:

```bash
claude-docker --ephemeral --ro ~/untrusted-repo
```

To keep one repo writable and give the agent read-only access to others, pass those as `--ro=PATH`. A `--ro=PATH` counts as a workspace, so `$PWD` is only the default when no workspace is given at all; pass `.` to keep it. The first workspace is the working directory, `--ro=` ones included:

```bash
claude-docker ~/repo --ro=~/shared-modules --ro=~/reference-repo
claude-docker . --ro=../shared-modules    # $PWD writable, shared-modules read-only
claude-docker --ro=. --ro=../shared       # both read-only; $PWD is the working dir
```

A `--ro=PATH` directory inside a writable workspace (`~/repo --ro=~/repo/vendor`), also through a symlink, is still writable through the outer mount; `claude-docker` warns when it sees one. Passing one directory both read-write and read-only (`~/repo --ro=~/repo`, or through a symlink) is refused. These checks compare paths exactly, so on a case-insensitive filesystem (macOS default) `~/repo --ro=~/Repo/vendor` slips past them: type paths with their real case.

`--ro=PATH` protects that directory, not the rest of the session: the agent can still act on what it reads there by writing to the writable workspaces, including git hooks or an `.envrc` the host later runs. For an untrusted repo, use `--ro` so that every workspace is read-only, or give it a session of its own (`--ephemeral --ro`).

For `--iterm` / `--tmux` (teammate split panes), see [Split-pane agent teams](#split-pane-agent-teams). In-container YOLO narrows the blast radius compared to running on the host, but see [Threat model](security.md#threat-model) for what it does and doesn't protect.

### Resuming sessions

The container starts `claude` directly, so there is no shell to type `claude --resume` in. Pass the flag through the wrapper instead, after `--`:

```bash
claude-docker ~/repo -- --resume                # pick from this workspace's sessions
claude-docker ~/repo -- --resume <session-id>   # resume a specific session
claude-docker ~/repo -- --continue              # resume the most recent session
```

Inside a running session, `/resume` opens the same picker. In the picker, `Ctrl+A` lists sessions from every workspace you've used, not just the current one.

Sessions are listed per container path, `/workspaces/<basename>` of the first workspace. A session started from `~/repo` shows up without `Ctrl+A` only when you launch with a first workspace named `repo` again; two host directories with the same basename share one list.

Conversation history persists in the shared `claude-code-home` volume. Under `--ephemeral` it doesn't, so there is nothing to resume.

## Host config parity

On every run, these items are dereferenced (symlinks resolved) and bind-mounted read-only into the container at the equivalent `/root/.claude/` path:

| Item                              | Purpose                       |
| --------------------------------- | ----------------------------- |
| `~/.claude/agents/`               | custom agent definitions      |
| `~/.claude/skills/`               | custom skills                 |
| `~/.claude/commands/`             | slash commands                |
| `~/.claude/themes/`               | custom themes                 |
| `~/.claude/CLAUDE.md`             | global preferences (`gprefs`) |
| `~/.claude/statusline-command.sh` | statusline renderer           |

The mounts are read-only. For `themes/` that means you can select a custom theme in the container, but saving one from the `/theme` editor fails with "theme save failed": edit themes on the host and they apply on the next start.

`TERM` and `COLORTERM` are forwarded from the host terminal, so Claude Code renders in truecolor when the host does. Without `COLORTERM` it drops to 256 colours and custom theme colours come out rounded. Ghostty's `TERM=xterm-ghostty` resolves to the `ghostty` terminfo entry from Ubuntu's `ncurses-term`, so `tput`, `less` and `--tmux` recognise the terminal.

For `settings.json`, maintain a dedicated `~/.claude/settings.docker.json` (any valid Claude `settings.json` schema) — when present it's copied to `/root/.claude/settings.json` at container start. A copy rather than a bind mount, because Claude Code saves settings by renaming a tmp file over `settings.json` and `rename()` over a mountpoint fails with `EBUSY` — so in-session settings changes (effort, model, theme) actually save; they last for that container run, are re-seeded from the host file on the next start, and are never written back to the host. Keeping it separate from your host `settings.json` avoids dragging macOS-only keys (`sandbox`, `env.SSL_CERT_FILE`, `enabledPlugins`) or host-filesystem `hooks` into the container. See [`examples/settings.docker.json`](../examples/settings.docker.json) for a starting point.

### Alternate Claude config dirs (`--claude-dir`)

If you keep more than one host Claude config (e.g. a personal `~/.claude/` and a work-only `~/.claude-work/`), point the wrapper at the one you want with `--claude-dir=PATH` or the `CLAUDE_DOCKER_CONFIG_DIR` env var:

```bash
claude-docker --claude-dir=~/.claude-work ~/repo
CLAUDE_DOCKER_CONFIG_DIR=~/.claude-work claude-docker ~/repo
```

The chosen dir takes the place of `~/.claude` for every item in the parity table above (agents, skills, commands, themes, `CLAUDE.md`, statusline, `settings.docker.json`).

### Git identity

`user.name` and `user.email` from your global git config (`~/.gitconfig`) are forwarded automatically as `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` so in-container `git commit` works out of the box with your real identity — no `git -c user.email=...` dance, no wrong-author commits. Not gated by a flag: identity is already public on every commit you've made. Signing keys, credential helpers, aliases, and hooks are NOT forwarded — those are host-specific (keychains, absolute paths) and would misfire inside the container.

### Statusline tag for active opt-ins

`run.sh` exports `CLAUDE_DOCKER_FLAGS` into the container with the comma-separated list of active opt-ins (`aws`, `gh`, `gh-direct`, `glab`, `glab-direct`, `tfe`, `az`, `registry`, `api`, `api-direct`, `egress-lock`, `ephemeral`, `ro`, `ro-partial`) and wraps the host statusline script so a yellow `docker:<flags>` tag is prepended to whatever your personal statusline renders. The variable is set by the wrapper for the statusline to read — not a user-tunable knob. `ro` means every workspace is read-only; `ro-partial` means only the `--ro=PATH` ones are. The tag reports mount flags, not effective protection: a read-only workspace inside a writable one still shows `ro-partial`. `--yolo` / `--dangerously-skip-permissions` is not surfaced here — Claude Code's own mode indicator already makes it obvious. The wrapper is a no-op passthrough when no opt-ins are active, so your statusline looks unchanged on a plain `claude-docker ~/repo`.

The image sets `IS_SANDBOX=1` — historically required to let `--yolo` / `--dangerously-skip-permissions` work when claude ran as root. The entrypoint now drops to the host UID before exec'ing claude, so the root-user check no longer triggers in steady state; `IS_SANDBOX=1` remains as a safety net for the legacy `HOST_UID=0` fall-through path. OS-level hardening comes from `--cap-drop ALL` (with `CHOWN`, `SETUID`, `SETGID`, `DAC_READ_SEARCH` re-added for transient entrypoint use only), `--security-opt no-new-privileges`, the Docker default seccomp profile, `--init` (tini reaps subprocess zombies), and the bind-mount layout. See [File ownership](#file-ownership) below and [Threat model](security.md#threat-model).

### Cost

claude-docker does not add a cost to the statusline. Claude Code passes the session's cost so far to your statusline script as `.cost.total_cost_usd`, in the container as on the host; show it wherever your layout wants it.

For spend across sessions, run [`ccusage`](https://github.com/ryoppippi/ccusage) on demand; the image does not ship it. Run it from `~`, because `pnpm dlx` creates a `.pnpm-store/` in the current directory:

```bash
cd ~ && pnpm dlx ccusage@20.0.26 daily
```

It reads the transcripts in the `claude-code-home` volume, so it reports container sessions only, not host sessions.

## File ownership

Files created inside the container appear on the host owned by the user who launched `claude-docker`, not by `root`. The wrapper forwards `HOST_UID` / `HOST_GID` and the in-container entrypoint creates a matching passwd entry and drops to it via `runuser` before exec'ing claude. Persistent state in the `claude-code-root` and `claude-code-home` named volumes is chowned on first start, so an existing volume from before this change is fixed up the next time you run `claude-docker`.

## Git worktrees

Git worktrees embed the path between the worktree and its repo's `.git/` in two link files. By default those paths are absolute, so a worktree created on the host breaks inside the container (and vice versa) because the same files sit at different absolute paths in each environment.

**No host config change needed.** For every workspace whose `.git/config` is a regular file (i.e. the main repo, not a worktree pointer), `claude-docker` overlays a container-only copy of `.git/config` that declares `extensions.relativeWorktrees = true` and `worktree.useRelativePaths = true`. The host's on-disk `.git/config` is never touched. Worktrees created inside the container therefore get relative paths, and those link files are then portable to the host without any opt-in. A `.git` or `.git/config` that is a symlink is never followed: that workspace gets no overlay, because the workspace is container-writable and following the link could copy a host file from outside it into the container.

This asymmetry is deliberate: the extension flag — when written into the host's `.git/config` — blinds tools that bundle an older libgit2 (notably `gitstatusd`, which powers the Powerlevel10k git prompt), because they refuse to open a v1 repo declaring an extension they don't know. Keeping the flag container-only sidesteps that.

To convert pre-existing absolute-path worktrees, ask Claude to run `git worktree repair --relative-paths <worktree-path>`, or type it yourself as `! git worktree repair --relative-paths <worktree-path>`. New worktrees added in the container get relative paths automatically.

**Trade-off:** container-side `git config` writes (e.g. `git remote add ...` writing to local config) land in the ephemeral overlay and are discarded when the container exits. Persistent `git config` edits should happen on the host.

**Fallback — `git worktree repair` (no flag):** ask Claude to run it, or type `! git worktree repair`.

Use this when you passed a repo and a _sibling_ worktree as separate workspace args (`claude-docker ~/repo ~/repo-feature`). Sibling-flattened mounts collapse the parent directory, so the relative offset between worktree and repo is not preserved by the bind mount and relative paths can't help.

**Caveats:**

- The overlay only applies to workspaces whose `.git` is a real directory (the main repo). If you mount only a worktree without its main repo, no overlay is created for it. Mount the main repo alongside if you need bidirectional worktree work.
- Relative paths assume the worktree's location relative to the repo's `.git/` is the same in both environments. Nested layouts (e.g. `<repo>/.claude/worktrees/<name>`) always satisfy this; moving a worktree to a totally different parent dir breaks both relative and absolute setups.

## Networks without DNS

The container uses the host's DNS server but not the host's `/etc/hosts`, so a forge reachable on the host only through an `/etc/hosts` entry doesn't resolve inside it, and `git push` over HTTPS, `gh`, `glab` and `az` fail. Set `CLAUDE_DOCKER_ADD_HOSTS` to the same entries, comma-separated:

```bash
export CLAUDE_DOCKER_ADD_HOSTS=gitlab.example.com:10.1.2.3,devops.example.com:10.1.2.4
```

Each entry is passed to the runtime as `--add-host`, and so lands in the container's `/etc/hosts`; the `--gh` auth-proxy sidecar gets them too, and so does the `--egress-lock` proxy, which resolves every name the session connects to. Under `--egress-allowlist` an entry decides where a listed name connects, not whether it may: the name must still be on the [allowlist](auth.md#egress-allowlist), and the session's `.meta` records the entries. Under `--gh`, entries for `github.com`, `api.github.com` and `uploads.github.com` are skipped for the agent container with a warning, since those must resolve to the sidecar. An entry that isn't `host:ip` stops `claude-docker` before any container starts.

## Pasting images

`Cmd-V` to paste a clipboard image doesn't work inside the container — Claude Code reads the macOS clipboard via OS APIs that a Linux container can't reach. Workaround: save the image into any workspace you mounted (e.g. `Cmd-Shift-4` to Desktop, then move it into `~/repo`) and reference it from Claude with `@screenshot.png`.

## Split-pane agent teams

Claude's teammate feature needs tmux. Two modes:

| Flag               | Env var equivalent      | Effect                                                                                                 |
| ------------------ | ----------------------- | ------------------------------------------------------------------------------------------------------ |
| _(none — default)_ | _(unset)_               | No tmux. Teammates fall back to Claude's **in-process** mode; cycle with Shift+Down.                   |
| `--tmux`           | `CLAUDE_DOCKER_TMUX=1`  | Plain tmux. Teammates = tmux splits in one terminal tab; switch with `C-b` + arrow keys. Any terminal. |
| `--iterm`          | `CLAUDE_DOCKER_TMUX=cc` | `tmux -CC` (iTerm2 control mode). Teammates = **native iTerm2 panes/tabs**. macOS + iTerm2 only.       |

The env vars are handy for `export` in your shell rc; the flags are handy for one-offs. Both modes need `teammateMode` set in `settings.docker.json` — see [`examples/settings.docker.json`](../examples/settings.docker.json). The image already bakes in `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, so you don't need to add that env var yourself.

### iTerm2 tips for `cc` mode

- Launch from a tab that is **not** already inside a host `tmux -CC` session — nesting degrades the inner server to plain splits.
- iTerm2 → Settings → General → tmux → Attaching → **"When attaching, restore windows as:"** → `Tabs in the attaching window` keeps the gateway and Claude's content inside one iTerm2 window (default is `Native windows`, which spawns a separate window).
- iTerm2 → Settings → General → tmux → **"Automatically bury the tmux client session after connecting"** → hides the `** tmux mode started **` gateway tab on attach so only the Claude tab is visible. Retrieve the gateway later via Session → Buried Sessions if needed.
- The UTF-8 warning from earlier builds is resolved — the image sets `LANG=C.UTF-8` and `run.sh` passes `tmux -u`.

## Extending the image

When a project needs extra tooling (language runtimes, package managers, project-scoped CLIs) that doesn't belong in the base image, build a child image and reuse this wrapper via the `CLAUDE_DOCKER_IMAGE` env var — no need to fork `run.sh`.

In the child repo:

```dockerfile
# .claude-docker/Dockerfile
FROM claude-code:local
RUN ...   # add your extras here
```

```bash
#!/usr/bin/env bash
# claude-docker (project-root entrypoint)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
IMAGE="claude-code-myproject:local"
docker build -t "$IMAGE" "$here/.claude-docker"
CLAUDE_DOCKER_IMAGE="$IMAGE" exec claude-docker "$@"
```

The child Dockerfile uses `FROM claude-code:local` (locally-built tag) — assumes the base has been built once on the host. Every wrapper flag (`--aws`, `--gh`, `--ephemeral`, `--ro`, `--iterm`, …) keeps working because the child script just exec's into this one with a different image tag.

Any extra package managers a child image installs (rustup, go, ruby, etc.) _add_ to the runtime code-fetch surface noted under [Threat model](security.md#threat-model) — they don't replace the existing `npx`/`pnpm dlx`/`uvx` primitives.
