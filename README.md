# claude-docker

Hardened Docker container for running Claude Code. Filesystem access is scoped to the directories you pass in; your host statusline, skills, agents, and commands come along via read-only bind-mounts.

## Install

```bash
# Build the image (one-time; rerun after Dockerfile changes)
docker build -t claude-code:local ~/git-work/stefanwb/claude-shared/claude-docker

# Put on your PATH
ln -s ~/git-work/stefanwb/claude-shared/claude-docker/run.sh ~/bin/claude-docker
```

## Usage

```bash
claude-docker                             # current dir as workspace
claude-docker ~/repo-a ~/repo-b           # multi-workspace
claude-docker --yolo ~/repo               # alias for --dangerously-skip-permissions
claude-docker ~/repo -- --resume          # any claude flag after --
```

`claude --resume` + Ctrl+A lists sessions from every workspace you've ever used (shared Docker volume). In-container YOLO is safer than on host — the container IS the sandbox.

## Host config parity

On every run, these items are dereferenced (symlinks resolved) and bind-mounted read-only into the container at the equivalent `/root/.claude/` path:

| Item                              | Purpose                             |
|-----------------------------------|-------------------------------------|
| `~/.claude/agents/`               | custom agent definitions            |
| `~/.claude/skills/`               | custom skills                       |
| `~/.claude/commands/`             | slash commands                      |
| `~/.claude/CLAUDE.md`             | global preferences (`gprefs`)       |
| `~/.claude/statusline-command.sh` | statusline renderer                 |

A curated `settings.json` is generated at runtime from your host's (`jq` required), containing only: `statusLine`, `effortLevel`, `autoUpdatesChannel`, `voiceEnabled`, `model`. The `sandbox` block, `env.SSL_CERT_FILE`, `enabledPlugins`, and `hooks` are stripped — host hooks exist to protect the host filesystem, and Docker already isolates yours.

## Auth model

| CLI   | Source                                                      |
|-------|-------------------------------------------------------------|
| gh    | Host uses macOS Keychain → `gh auth login` once inside container (persists via volume) |
| glab  | Bind-mounts `~/Library/Application Support/glab-cli` (macOS) or `~/.config/glab-cli` (Linux) |
| aws   | Bind-mounts `~/.aws/`                                       |

Env vars forwarded when set on host: `GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN`, `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`.

## Filesystem isolation

Only your passed workspace dirs are visible on the host side. Container runs with `--cap-drop ALL` and `--security-opt no-new-privileges`. Full egress network.

## Git worktrees

Sibling worktrees need a one-time repair inside the container because `.git` points to a host-absolute path:

```bash
# inside the container, in the worktree:
git worktree repair
```

## Split-pane agent teams

Set `CLAUDE_DOCKER_TMUX=1` to wrap `claude` in a container-local tmux session (required for Claude Code's split-pane teammates feature).

## Specs

Behavioural requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).
