# claude-docker

Hardened Docker container for running Claude Code. Filesystem access is scoped to the directories you pass in; your host statusline, skills, agents, and commands come along via read-only bind-mounts.

## Install

```bash
# Build the image from your checkout (one-time; rerun after Dockerfile changes)
docker build -t claude-code:local ./claude-docker

# Put on your PATH (create ~/bin if it doesn't exist)
mkdir -p ~/bin
ln -s "$(pwd)/claude-docker/run.sh" ~/bin/claude-docker
```

## Usage

```bash
claude-docker                             # current dir as workspace
claude-docker ~/repo-a ~/repo-b           # multi-workspace
claude-docker --yolo ~/repo               # alias for --dangerously-skip-permissions
claude-docker ~/repo -- --resume          # any claude flag after --
```

`claude-docker --help` (or `-h`) prints every wrapper flag with a one-line explanation — the canonical reference.

### Credential opt-in

**Credentials are off by default.** No AWS / GitHub / GitLab config, tokens, or env vars reach the container unless you explicitly opt in:

| Flag         | Effect |
|--------------|--------|
| `--aws`      | Mount `~/.aws/config` + `~/.aws/sso` (:ro) and forward `AWS_PROFILE`/`AWS_REGION`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`. |
| `--gh`       | Forward `GH_TOKEN`/`GITHUB_TOKEN` **and** unmask in-container `gh auth login` state persisted in `claude-code-root`. Without this flag, `/root/.config/gh/` is hidden by a tmpfs overlay so a prior login can't leak into a non-opted-in session. |
| `--glab`     | Mount the platform-appropriate `glab-cli` config dir (:ro) and forward `GITLAB_TOKEN`. Also unmasks any in-container `glab auth login` state; without the flag, `/root/.config/glab-cli/` is hidden by a tmpfs overlay. |

Combine as needed: `claude-docker --aws --gh ~/repo`.

### Other hardening flags

| Flag            | Effect |
|-----------------|--------|
| `--ephemeral`   | Skip the `claude-code-root` and `claude-code-home` named volumes. No Claude OAuth token, `gh` login, or conversation history persists across runs. Use for one-shot sessions on untrusted workspaces. |
| `--ro`          | Mount every workspace read-only. Code review / audit mode. |
| `--iterm`       | Wrap `claude` in `tmux -CC` for native iTerm2 split-pane teammates (macOS + iTerm2). See [Split-pane agent teams](#split-pane-agent-teams). |
| `--tmux`        | Wrap `claude` in plain tmux. Teammates render as tmux splits in one terminal tab. Works anywhere. |

Example — review-only session on an untrusted repo, zero creds, no persistence:

```bash
claude-docker --ephemeral --ro ~/untrusted-repo
```

In-container YOLO narrows the blast radius compared to running on the host, but see [Threat model](#threat-model) for what it does and doesn't protect.

### Resuming sessions across workspaces

Conversation history persists in the shared `claude-code-home` volume (skipped under `--ephemeral`), so `claude --resume` followed by `Ctrl+A` lists sessions from every workspace you've ever used — not just the one you're currently in.

## Host config parity

On every run, these items are dereferenced (symlinks resolved) and bind-mounted read-only into the container at the equivalent `/root/.claude/` path:

| Item                              | Purpose                             |
|-----------------------------------|-------------------------------------|
| `~/.claude/agents/`               | custom agent definitions            |
| `~/.claude/skills/`               | custom skills                       |
| `~/.claude/commands/`             | slash commands                      |
| `~/.claude/CLAUDE.md`             | global preferences (`gprefs`)       |
| `~/.claude/statusline-command.sh` | statusline renderer                 |

For `settings.json`, maintain a dedicated `~/.claude/settings.docker.json` (any valid Claude `settings.json` schema) — it's bind-mounted at `/root/.claude/settings.json` when present. Keeping it separate from your host `settings.json` avoids dragging macOS-only keys (`sandbox`, `env.SSL_CERT_FILE`, `enabledPlugins`) or host-filesystem `hooks` into the container. See [`examples/settings.docker.json`](examples/settings.docker.json) for a starting point.

### Git identity

`user.name` and `user.email` from your global git config (`~/.gitconfig`) are forwarded automatically as `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` so in-container `git commit` works out of the box with your real identity — no `git -c user.email=...` dance, no wrong-author commits. Not gated by a flag: identity is already public on every commit you've made. Signing keys, credential helpers, aliases, and hooks are NOT forwarded — those are host-specific (keychains, absolute paths) and would misfire inside the container.

### Statusline tag for active opt-ins

`run.sh` exports `CLAUDE_DOCKER_FLAGS` into the container with the comma-separated list of active opt-ins (`gh`, `aws`, `glab`, `ephemeral`, `ro`) and wraps the host statusline script so a yellow `docker:<flags>` tag is prepended to whatever your personal statusline renders. `--yolo` / `--dangerously-skip-permissions` is not surfaced here — Claude Code's own mode indicator already makes it obvious. The wrapper is a no-op passthrough when no opt-ins are active, so your statusline looks unchanged on a plain `claude-docker ~/repo`.

The image sets `IS_SANDBOX=1` so `--yolo` / `--dangerously-skip-permissions` works despite running as root. See [Threat model](#threat-model) below.

## Auth model

Credentials are opt-in per run (see [Credential opt-in](#credential-opt-in) above). When enabled:

| Flag         | Source                                                      |
|--------------|-------------------------------------------------------------|
| `--gh`       | In-container `gh auth login` persists via `claude-code-root` volume (host macOS Keychain is not reachable), but is only visible when `--gh` is passed — otherwise `/root/.config/gh/` is masked by a tmpfs. Host `GH_TOKEN`/`GITHUB_TOKEN` env vars are forwarded when set. |
| `--glab`     | Read-only bind-mount of `~/Library/Application Support/glab-cli` (macOS) or `~/.config/glab-cli` (Linux). Any in-container `glab auth login` state is likewise only visible under `--glab`; without the flag `/root/.config/glab-cli/` is masked by a tmpfs. Host `GITLAB_TOKEN` env var forwarded when set. |
| `--aws`      | Read-only bind-mount of `~/.aws/config` and `~/.aws/sso/` only. `~/.aws/credentials` (long-lived keys) and `~/.aws/cli/cache/` are **not** exposed. Host `AWS_PROFILE`/`AWS_REGION`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` forwarded when set. |

### AWS SSO flow (`--aws`)

Standard SSO usage works unchanged: `aws sso login --profile X && export AWS_PROFILE=X` on the host, then `claude-docker --aws`. The container reads the short-lived SSO bearer token from `~/.aws/sso/cache` via the read-only mount.

If you'd rather not mount `sso/cache` either, flatten to env vars after login:

```bash
aws sso login --profile X
eval "$(aws configure export-credentials --profile X --format env)"
claude-docker --aws ...
```

Container then uses `AWS_ACCESS_KEY_ID`/`SECRET`/`SESSION_TOKEN` and the SSO cache is not needed inside. Temp creds freeze at container start (~1h TTL).

## Threat model

The container narrows blast radius vs. running `claude --yolo` on the host, but it is **not** a full sandbox:

- **Protected:** host filesystem outside your passed workspaces, host `~/.aws/credentials` (long-lived keys), host AWS/glab config dirs are read-only from inside (container can't persist changes back).
- **Exposed:** your passed workspaces are read-write; short-lived AWS SSO bearer tokens (`~/.aws/sso/cache`) and the glab config token are readable inside the container; `gh`/`GITLAB_TOKEN` env vars are readable; full outbound network.
- **Implication:** a prompt-injected file in any mounted workspace can exfiltrate those tokens and read/write any workspace. Don't mount repos you don't trust. Rotate tokens if the container is compromised.

Hardening applied: `--cap-drop ALL`, `--security-opt no-new-privileges`, pinned base image + app versions with sha256 verification on downloaded artifacts.

## Git worktrees

Sibling worktrees need a one-time repair inside the container because `.git` points to a host-absolute path:

```bash
# inside the container, in the worktree:
git worktree repair
```

## Pasting images

`Cmd-V` to paste a clipboard image doesn't work inside the container — Claude Code reads the macOS clipboard via OS APIs that a Linux container can't reach. Workaround: save the image into any workspace you mounted (e.g. `Cmd-Shift-4` to Desktop, then move it into `~/repo`) and reference it from Claude with `@screenshot.png`.

## Split-pane agent teams

Claude's teammate feature needs tmux. Two modes:

| Flag       | Env var equivalent       | Effect |
|------------|--------------------------|--------|
| *(none — default)* | *(unset)*        | No tmux. Teammates fall back to Claude's **in-process** mode; cycle with Shift+Down. |
| `--tmux`   | `CLAUDE_DOCKER_TMUX=1`   | Plain tmux. Teammates = tmux splits in one terminal tab; switch with `C-b` + arrow keys. Any terminal. |
| `--iterm`  | `CLAUDE_DOCKER_TMUX=cc`  | `tmux -CC` (iTerm2 control mode). Teammates = **native iTerm2 panes/tabs**. macOS + iTerm2 only. |

The env vars are handy for `export` in your shell rc; the flags are handy for one-offs. Both modes need `teammateMode` set in `settings.docker.json` — see [`examples/settings.docker.json`](examples/settings.docker.json). The image already bakes in `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, so you don't need to add that env var yourself.

### iTerm2 tips for `cc` mode

- Launch from a tab that is **not** already inside a host `tmux -CC` session — nesting degrades the inner server to plain splits.
- iTerm2 → Settings → General → tmux → Attaching → **"When attaching, restore windows as:"** → `Tabs in the attaching window` keeps the gateway and Claude's content inside one iTerm2 window (default is `Native windows`, which spawns a separate window).
- iTerm2 → Settings → General → tmux → **"Automatically bury the tmux client session after connecting"** → hides the `** tmux mode started **` gateway tab on attach so only the Claude tab is visible. Retrieve the gateway later via Session → Buried Sessions if needed.
- The UTF-8 warning from earlier builds is resolved — the image sets `LANG=C.UTF-8` and `run.sh` passes `tmux -u`.

## Specs

Behavioural requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).
