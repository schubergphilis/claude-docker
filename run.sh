#!/usr/bin/env bash
set -euo pipefail

IMAGE="claude-code:local"

# Keep this in sync with the flag-parsing case statement below — adding or
# removing a wrapper flag means updating both the case branch and this heredoc
# in the same diff.
print_help() {
  cat <<'EOF'
Usage: claude-docker [OPTIONS] [WORKSPACE...] [-- CLAUDE_FLAGS...]

Hardened Docker wrapper for Claude Code. Wrapper flags and workspace paths
are parsed before `--`; anything after `--` is forwarded verbatim to the
`claude` binary inside the container.

Workspaces:
  WORKSPACE...        One or more host directories to mount at
                      /workspaces/<basename>. Defaults to $PWD when omitted.
                      First workspace becomes the container's working dir.

Wrapper flags:
  -h, --help          Print this help and exit 0 without starting Docker.
  --yolo              Pass --dangerously-skip-permissions to claude.
  --ephemeral         Skip the claude-code-root/claude-code-home named
                      volumes. No OAuth token, gh login, shell history, or
                      session history persists across runs.
  --ro                Mount every workspace read-only (review / audit mode).
  --aws               Opt in to AWS: mount ~/.aws/config + ~/.aws/sso (:ro)
                      and forward AWS_PROFILE / AWS_REGION /
                      AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
                      AWS_SESSION_TOKEN when set.
  --gh                Opt in to GitHub: forward GH_TOKEN / GITHUB_TOKEN and
                      unmask in-container gh login state.
  --glab              Opt in to GitLab: mount glab-cli config (:ro) and
                      forward GITLAB_TOKEN; unmask in-container glab login.
  --iterm             Wrap claude in tmux -CC (iTerm2 control mode → native
                      panes). Equivalent to CLAUDE_DOCKER_TMUX=cc.
  --tmux              Wrap claude in plain tmux (works in any terminal).
                      Equivalent to CLAUDE_DOCKER_TMUX=1.

Separator:
  --                  Ends wrapper-flag parsing. Everything after is passed
                      to `claude`, e.g. `claude-docker ~/repo -- --resume`.

Environment:
  CLAUDE_DOCKER_TMUX  1  → plain tmux wrapper (same as --tmux).
                      cc → tmux -CC iTerm2 control mode (same as --iterm).

Credentials are off by default; combine opt-ins as needed:
  claude-docker --aws --gh ~/repo
EOF
}

# Wrapper flags and workspace paths before `--`; verbatim claude flags after.
# See `print_help` above or `claude-docker --help` for the flag list.
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
    -h|--help)   print_help; exit 0 ;;
    --yolo)      CLAUDE_FLAGS+=("--dangerously-skip-permissions") ;;
    --ephemeral) EPHEMERAL=1 ;;
    --ro)        RO_WORKSPACES=1 ;;
    --aws)       WITH_AWS=1 ;;
    --gh)        WITH_GH=1 ;;
    --glab)      WITH_GLAB=1 ;;
    --iterm)     CLAUDE_DOCKER_TMUX=cc ;;
    --tmux)      CLAUDE_DOCKER_TMUX=1 ;;
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
# Counter-based iteration avoids ${!arr[@]} which trips set -u on empty arrays.
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
  n=${#SEEN_NAMES[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${SEEN_NAMES[$i]}" = "$name" ]; then
      echo "claude-docker: workspace basename collision — '$abs' and '${SEEN_PATHS[$i]}' both map to /workspaces/$name" >&2
      exit 1
    fi
    i=$((i + 1))
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
# Guarded: bash 3.2 under `set -u` errors on empty-array expansion.
if [ "${#ENV_VARS[@]}" -gt 0 ]; then
  for v in "${ENV_VARS[@]}"; do
    [ -n "${!v:-}" ] && ENV_ARGS+=("-e" "$v")
  done
fi

# Surface active opt-ins in-container via CLAUDE_DOCKER_FLAGS so the statusline
# wrapper (below) can tag the session with what was actually granted. Order
# mirrors the README table so the tag reads predictably.
# --yolo is omitted intentionally: Claude Code already shows the permission
# mode in its UI, so duplicating it here would just be noise.
DOCKER_FLAGS=()
[ "$WITH_GH" = "1" ]       && DOCKER_FLAGS+=("gh")
[ "$WITH_AWS" = "1" ]      && DOCKER_FLAGS+=("aws")
[ "$WITH_GLAB" = "1" ]     && DOCKER_FLAGS+=("glab")
[ "$EPHEMERAL" = "1" ]     && DOCKER_FLAGS+=("ephemeral")
[ "$RO_WORKSPACES" = "1" ] && DOCKER_FLAGS+=("ro")
if [ "${#DOCKER_FLAGS[@]}" -gt 0 ]; then
  old_ifs=$IFS; IFS=','; DOCKER_FLAGS_CSV="${DOCKER_FLAGS[*]}"; IFS=$old_ifs
  ENV_ARGS+=("-e" "CLAUDE_DOCKER_FLAGS=$DOCKER_FLAGS_CSV")
fi

# Host Claude config parity: dereference symlinks (skills/agents often point
# into shared repos) into a staging dir, then bind-mount read-only.
stage=$(mktemp -d -t claude-docker-host.XXXXXX)
# `case` instead of `[[ ]]` for bash 3.2 friendliness inside the trap string.
trap 'case "$stage" in */claude-docker-host.*) rm -rf "$stage" ;; esac' EXIT

for item in agents commands skills; do
  if [ -d "$HOME/.claude/$item" ]; then
    cp -RL "$HOME/.claude/$item" "$stage/$item"
    MOUNT_ARGS+=("-v" "$stage/$item:/root/.claude/$item:ro")
  fi
done
if [ -f "$HOME/.claude/CLAUDE.md" ]; then
  cp -L "$HOME/.claude/CLAUDE.md" "$stage/CLAUDE.md"
  MOUNT_ARGS+=("-v" "$stage/CLAUDE.md:/root/.claude/CLAUDE.md:ro")
fi

# Statusline: mount the host script as-is, plus a thin wrapper at the canonical
# path that prefixes a `docker:<flags>` tag when CLAUDE_DOCKER_FLAGS is set.
# The wrapper is a no-op passthrough when unset so non-claude-docker runs of
# the same file would behave identically.
if [ -f "$HOME/.claude/statusline-command.sh" ]; then
  cp -L "$HOME/.claude/statusline-command.sh" "$stage/statusline-command.original.sh"
  chmod +x "$stage/statusline-command.original.sh"
  cat >"$stage/statusline-command.sh" <<'WRAP'
#!/bin/sh
# claude-docker wrapper — prepends active opt-in flag tag to host statusline.
input=$(cat)
body=$(printf '%s' "$input" | /root/.claude/statusline-command.original.sh)
if [ -n "${CLAUDE_DOCKER_FLAGS:-}" ]; then
  printf '\033[33mdocker:%s\033[0m %s' "$CLAUDE_DOCKER_FLAGS" "$body"
else
  printf '%s' "$body"
fi
WRAP
  chmod +x "$stage/statusline-command.sh"
  MOUNT_ARGS+=(
    "-v" "$stage/statusline-command.original.sh:/root/.claude/statusline-command.original.sh:ro"
    "-v" "$stage/statusline-command.sh:/root/.claude/statusline-command.sh:ro"
  )
fi
[ -f "$HOME/.claude/settings.docker.json" ] \
  && MOUNT_ARGS+=("-v" "$HOME/.claude/settings.docker.json:/root/.claude/settings.json:ro")

CMD=(claude)
[ "${#CLAUDE_FLAGS[@]}" -gt 0 ] && CMD+=("${CLAUDE_FLAGS[@]}")
# CLAUDE_DOCKER_TMUX=1   → plain tmux (works in any terminal)
# CLAUDE_DOCKER_TMUX=cc  → tmux -CC, iTerm2 control mode (native panes on macOS).
#                          Host must NOT already be inside tmux -CC — nesting
#                          collapses the inner server to plain splits.
case "${CLAUDE_DOCKER_TMUX:-0}" in
  cc|CC) CMD=(tmux -u -CC new-session -A -s claude "${CMD[@]}") ;;
  1)     CMD=(tmux -u     new-session -A -s claude "${CMD[@]}") ;;
esac

# Persistent named volumes carry OAuth tokens, gh login, conversation history.
# --ephemeral skips them for one-shot untrusted sessions. Prepend to MOUNT_ARGS
# so the docker run line has no conditionally-empty array (bash 3.2 set -u).
if [ "$EPHEMERAL" = "0" ]; then
  # Mask persisted in-container auth state when the opt-in flag is off, so a
  # prior `gh`/`glab auth login` stored under claude-code-root doesn't leak
  # into a session the user didn't ask to grant those creds to.
  [ "$WITH_GH" = "0" ]   && MOUNT_ARGS+=("--tmpfs" "/root/.config/gh")
  [ "$WITH_GLAB" = "0" ] && MOUNT_ARGS+=("--tmpfs" "/root/.config/glab-cli")
  MOUNT_ARGS=(-v claude-code-root:/root -v claude-code-home:/root/.claude "${MOUNT_ARGS[@]}")
fi

docker run --rm -it \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  "${MOUNT_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  -w "$CWD" \
  "$IMAGE" \
  "${CMD[@]}"
