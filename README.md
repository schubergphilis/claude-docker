# claude-docker

Hardened Docker container for running Claude Code. Isolates filesystem access to the directories you pass in, while keeping sessions, credentials, and common CLIs (`gh`, `glab`, `aws`) available.

## Quickstart

```bash
# One-time build
docker build -t claude-code:local .

# Run on current directory
./run.sh

# Run on multiple directories (enables sibling git worktrees, cross-repo work)
./run.sh ~/repo-a ~/repo-b

# Pass flags to claude after --
./run.sh ~/repo-a -- --resume
```

Sessions and credentials persist across runs in two named Docker volumes (`claude-code-root`, `claude-code-home`). `claude --resume` + `Ctrl+A` lists sessions from every workspace you've ever used.

## Auth model

| CLI   | Source                                                      |
|-------|-------------------------------------------------------------|
| gh    | Host uses macOS Keychain → fresh `gh auth login` in container (persists via volume) |
| glab  | Bind-mounts `~/Library/Application Support/glab-cli` (macOS) or `~/.config/glab-cli` (Linux) |
| aws   | Bind-mounts `~/.aws/` from host                             |

Env vars forwarded when set on host: `GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN`, `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN`.

## Filesystem isolation

Only the workspace directories you pass are visible to the container. Everything else on your host is invisible. Container runs with `--cap-drop ALL` and `--security-opt no-new-privileges`. Full egress network.

## Split-pane agent teams

Set `CLAUDE_DOCKER_TMUX=1` to wrap `claude` in a container-local tmux session (required for Claude Code's split-pane teammates feature).

## Specs

Behavioral requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).
