#!/usr/bin/env bash
set -euo pipefail

IMAGE="claude-code:local"

# Args parsing: workspaces and recognised flags before `--`, verbatim
# claude flags after `--`.
#   claude-docker ~/repo-a ~/repo-b -- --resume
#   claude-docker --yolo ~/repo-a                (-> claude --dangerously-skip-permissions)
#   claude-docker --ephemeral ~/repo             (no persistent named volumes)
#   claude-docker --ro ~/repo                    (read-only workspace mounts)
#   claude-docker --aws ~/repo                   (opt in to AWS config/sso + AWS_* env)
#   claude-docker --gh ~/repo                    (opt in to GH_TOKEN/GITHUB_TOKEN env)
#   claude-docker --glab ~/repo                  (opt in to glab config + GITLAB_TOKEN env)
# Credentials are off by default. Combine opt-ins as needed: `--aws --gh`.
WORKSPACES=()
CLAUDE_FLAGS=()
EPHEMERAL=0
RO_WORKSPACES=0
WITH_AWS=0
WITH_GH=0
WITH_GLAB=0
saw_sep=0
for arg in "$@"; do
  if [ "$arg" = "--" ]; then saw_sep=1; continue; fi
  if [ "$saw_sep" = "1" ]; then
    CLAUDE_FLAGS+=("$arg"); continue
  fi
  case "$arg" in
    --yolo)      CLAUDE_FLAGS+=("--dangerously-skip-permissions") ;;
    --ephemeral) EPHEMERAL=1 ;;
    --ro)        RO_WORKSPACES=1 ;;
    --aws)       WITH_AWS=1 ;;
    --gh)        WITH_GH=1 ;;
    --glab)      WITH_GLAB=1 ;;
    *)           WORKSPACES+=("$arg") ;;
  esac
done
[ "${#WORKSPACES[@]}" -eq 0 ] && WORKSPACES=("$PWD")

MOUNT_ARGS=()
ENV_ARGS=(-e TERM)
CONTAINER_PATHS=()

ws_suffix=""
[ "$RO_WORKSPACES" = "1" ] && ws_suffix=":ro"

# Parallel arrays (not associative) so macOS system bash 3.2 works.
SEEN_NAMES=()
SEEN_PATHS=()
for ws in "${WORKSPACES[@]}"; do
  abs=$(cd "$ws" && pwd)
  name=$(basename "$abs")
  case "$name" in
    *[!A-Za-z0-9._-]*|"")
      echo "claude-docker: workspace basename '$name' contains characters that break 'docker -v' parsing; allowed: [A-Za-z0-9._-]" >&2
      exit 1 ;;
  esac
  for i in "${!SEEN_NAMES[@]}"; do
    if [ "${SEEN_NAMES[$i]}" = "$name" ]; then
      echo "claude-docker: workspace basename collision — '$abs' and '${SEEN_PATHS[$i]}' both map to /workspaces/$name" >&2
      exit 1
    fi
  done
  SEEN_NAMES+=("$name")
  SEEN_PATHS+=("$abs")
  MOUNT_ARGS+=("-v" "$abs:/workspaces/$name$ws_suffix")
  CONTAINER_PATHS+=("/workspaces/$name")
done
CWD="${CONTAINER_PATHS[0]}"

# File-based host creds. gh uses macOS Keychain → log in inside the container once; persists via claude-code-root.
# glab on macOS lives under ~/Library/Application Support/glab-cli (not XDG); fall back to ~/.config/glab-cli on Linux.
if [ "$WITH_GLAB" = "1" ]; then
  glab_src=""
  if [ -d "$HOME/Library/Application Support/glab-cli" ]; then
    glab_src="$HOME/Library/Application Support/glab-cli"
  elif [ -d "$HOME/.config/glab-cli" ]; then
    glab_src="$HOME/.config/glab-cli"
  fi
  [ -n "$glab_src" ] && MOUNT_ARGS+=("-v" "$glab_src:/root/.config/glab-cli:ro")
fi

# Scoped AWS mount: only non-secret config + short-lived SSO bearer cache.
# Excludes ~/.aws/credentials (long-lived access keys) and ~/.aws/cli/cache
# (cached assume-role STS). Env-var flow (AWS_ACCESS_KEY_ID/...) still forwards
# below for users who flatten creds with `aws configure export-credentials`.
if [ "$WITH_AWS" = "1" ]; then
  [ -f "$HOME/.aws/config" ] && MOUNT_ARGS+=("-v" "$HOME/.aws/config:/root/.aws/config:ro")
  [ -d "$HOME/.aws/sso" ]    && MOUNT_ARGS+=("-v" "$HOME/.aws/sso:/root/.aws/sso:ro")
fi

ENV_VARS=()
[ "$WITH_GH" = "1" ]   && ENV_VARS+=(GH_TOKEN GITHUB_TOKEN)
[ "$WITH_GLAB" = "1" ] && ENV_VARS+=(GITLAB_TOKEN)
[ "$WITH_AWS" = "1" ]  && ENV_VARS+=(AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)
for v in "${ENV_VARS[@]}"; do
  [ -n "${!v:-}" ] && ENV_ARGS+=("-e" "$v")
done

# Host Claude config parity: dereference symlinks (skills/agents often point
# into shared repos) into a staging dir, then bind-mount read-only.
stage=$(mktemp -d -t claude-docker-host.XXXXXX)
trap '[[ "$stage" == */claude-docker-host.* ]] && rm -rf "$stage"' EXIT

for item in agents commands skills; do
  if [ -d "$HOME/.claude/$item" ]; then
    cp -RL "$HOME/.claude/$item" "$stage/$item"
    MOUNT_ARGS+=("-v" "$stage/$item:/root/.claude/$item:ro")
  fi
done
for item in CLAUDE.md statusline-command.sh; do
  if [ -f "$HOME/.claude/$item" ]; then
    cp -L "$HOME/.claude/$item" "$stage/$item"
    MOUNT_ARGS+=("-v" "$stage/$item:/root/.claude/$item:ro")
  fi
done
[ -f "$HOME/.claude/settings.docker.json" ] \
  && MOUNT_ARGS+=("-v" "$HOME/.claude/settings.docker.json:/root/.claude/settings.json:ro")

CMD=(claude)
[ "${#CLAUDE_FLAGS[@]}" -gt 0 ] && CMD+=("${CLAUDE_FLAGS[@]}")
[ "${CLAUDE_DOCKER_TMUX:-0}" = "1" ] && CMD=(tmux new-session -A -s claude "${CMD[@]}")

# Persistent named volumes carry OAuth tokens, gh login, conversation history.
# --ephemeral skips them for one-shot untrusted sessions.
PERSIST_ARGS=()
if [ "$EPHEMERAL" = "0" ]; then
  PERSIST_ARGS=(-v claude-code-root:/root -v claude-code-home:/root/.claude)
fi

docker run --rm -it \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  "${PERSIST_ARGS[@]}" \
  "${MOUNT_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  -w "$CWD" \
  "$IMAGE" \
  "${CMD[@]}"
