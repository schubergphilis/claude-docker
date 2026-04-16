#!/usr/bin/env bash
set -euo pipefail

IMAGE="claude-code:local"

# Args parsing: workspaces and recognised flags before `--`, verbatim
# claude flags after `--`.
#   claude-docker ~/repo-a ~/repo-b -- --resume
#   claude-docker --yolo ~/repo-a                (-> claude --dangerously-skip-permissions)
WORKSPACES=()
CLAUDE_FLAGS=()
saw_sep=0
for arg in "$@"; do
  if [ "$arg" = "--" ]; then saw_sep=1; continue; fi
  if [ "$saw_sep" = "1" ]; then
    CLAUDE_FLAGS+=("$arg"); continue
  fi
  case "$arg" in
    --yolo) CLAUDE_FLAGS+=("--dangerously-skip-permissions") ;;
    *)      WORKSPACES+=("$arg") ;;
  esac
done
[ "${#WORKSPACES[@]}" -eq 0 ] && WORKSPACES=("$PWD")

MOUNT_ARGS=()
ENV_ARGS=(-e TERM)
CONTAINER_PATHS=()

for ws in "${WORKSPACES[@]}"; do
  abs=$(cd "$ws" && pwd)
  name=$(basename "$abs")
  MOUNT_ARGS+=("-v" "$abs:/workspaces/$name")
  CONTAINER_PATHS+=("/workspaces/$name")
done
CWD="${CONTAINER_PATHS[0]}"

# File-based host creds. gh uses macOS Keychain → log in inside the container once; persists via claude-code-root.
# glab on macOS lives under ~/Library/Application Support/glab-cli (not XDG); fall back to ~/.config/glab-cli on Linux.
glab_src=""
if [ -d "$HOME/Library/Application Support/glab-cli" ]; then
  glab_src="$HOME/Library/Application Support/glab-cli"
elif [ -d "$HOME/.config/glab-cli" ]; then
  glab_src="$HOME/.config/glab-cli"
fi
[ -n "$glab_src" ] && MOUNT_ARGS+=("-v" "$glab_src:/root/.config/glab-cli")

[ -d "$HOME/.aws" ] && MOUNT_ARGS+=("-v" "$HOME/.aws:/root/.aws")

for v in GH_TOKEN GITHUB_TOKEN GITLAB_TOKEN AWS_PROFILE AWS_REGION \
         AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; do
  [ -n "${!v:-}" ] && ENV_ARGS+=("-e" "$v")
done

# Host Claude config parity: dereference symlinks (skills/agents often point
# into shared repos) into a staging dir, then bind-mount read-only.
stage="${TMPDIR:-/tmp}/claude-docker-host-$$"
mkdir -p "$stage"
trap 'rm -rf "$stage"' EXIT

for item in agents commands skills; do
  [ -d "$HOME/.claude/$item" ] && cp -RL "$HOME/.claude/$item" "$stage/$item" 2>/dev/null || true
  [ -d "$stage/$item" ] && MOUNT_ARGS+=("-v" "$stage/$item:/root/.claude/$item:ro")
done
for item in CLAUDE.md statusline-command.sh; do
  [ -f "$HOME/.claude/$item" ] && cp -L "$HOME/.claude/$item" "$stage/$item" && \
    MOUNT_ARGS+=("-v" "$stage/$item:/root/.claude/$item:ro")
done
[ -f "$HOME/.claude/settings.docker.json" ] \
  && MOUNT_ARGS+=("-v" "$HOME/.claude/settings.docker.json:/root/.claude/settings.json:ro")

CMD=(claude)
[ "${#CLAUDE_FLAGS[@]}" -gt 0 ] && CMD+=("${CLAUDE_FLAGS[@]}")
[ "${CLAUDE_DOCKER_TMUX:-0}" = "1" ] && CMD=(tmux new-session -A -s claude "${CMD[@]}")

docker run --rm -it \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  -v claude-code-root:/root \
  -v claude-code-home:/root/.claude \
  "${MOUNT_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  -w "$CWD" \
  "$IMAGE" \
  "${CMD[@]}"
