#!/usr/bin/env bats
# Unit tests for run.sh; docker, podman, gh, glab and git are stubbed as shell
# functions, so nothing here needs a container engine or network.
# Globals set here are read by the sourced run.sh functions (SC2034), and
# "~/cfg" is a deliberately literal tilde (SC2088).
# shellcheck disable=SC2034,SC2088

setup() {
  bats_require_minimum_version 1.5.0
  # shellcheck source=../../run.sh
  source "${BATS_TEST_DIRNAME}/../../run.sh"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  unset GH_TOKEN GITHUB_TOKEN GITLAB_TOKEN GITLAB_HOST CLAUDE_DOCKER_RUNTIME \
    CLAUDE_DOCKER_GH_POLICY CLAUDE_DOCKER_AZ_CA CLAUDE_DOCKER_API_CA \
    CLAUDE_DOCKER_TMUX CLAUDE_DOCKER_TEST_ENTRY CLAUDE_DOCKER_FLAGS ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY
  RUNTIME=docker
  # Knobs for the docker stub: STUB_FAIL names subcommands that fail,
  # STUB_PS is the stopped-container list, STUB_ALIVE the running sidecar id.
  STUB_FAIL="" STUB_PS="" STUB_ALIVE="cid" STUB_IP="10.0.0.2"
  docker() {
    echo "docker $*" >>"$CALLS"
    case " $STUB_FAIL " in *" $1 "*) return 1 ;; esac
    case "$1" in
      ps)
        if [ "$2" = "-aq" ]; then [ -z "$STUB_PS" ] || printf '%s\n' $STUB_PS
        else echo "$STUB_ALIVE"; fi ;;
      network) [ "$2" = "ls" ] && echo "net1"; return 0 ;;
      cp) echo "CA" >"$3" ;;
      inspect) echo "$STUB_IP" ;;
      logs) echo "caddy: bad policy" ;;
    esac
    return 0
  }
  podman() { echo "podman $*" >>"$CALLS"; }
  gh() { echo "gh $*" >>"$CALLS"; echo "gho_stub"; }
  glab() { echo "glab $*" >>"$CALLS"; [ "$2" = "get" ] && [ "$3" = "token" ] && echo "glpat_stub"; return 0; }
  git() {
    case "$*" in
      "config --global --get user.name") echo "Ada Lovelace" ;;
      "config --global --get user.email") echo "ada@example.com" ;;
      *) return 1 ;;
    esac
  }
  sleep() { :; }
  WS="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$WS"
}

# Newline-joined array, for substring assertions.
lines_of() { printf '%s\n' "$@"; }

# `set -e` is ignored inside `run`, so paths that depend on it run in a fresh
# bash: run_script executes run.sh itself, run_script_fn sources it under
# `set -euo pipefail` and evals $1. The stubs reach the child as exported
# functions.
export_stubs() {
  export -f docker podman gh glab git sleep
  export CALLS STUB_FAIL STUB_PS STUB_ALIVE STUB_IP
}
run_script() {
  export_stubs
  run "${BATS_TEST_DIRNAME}/../../run.sh" "$@"
}
run_script_fn() {
  export_stubs
  run bash -c 'set -euo pipefail; source "$1"; RUNTIME=docker; eval "$2"' _ \
    "${BATS_TEST_DIRNAME}/../../run.sh" "$1"
}

# --- parse_args ---

@test "parse_args: unknown flag is rejected" {
  run parse_args --bogus
  [ "$status" -eq 1 ]
  [ "$output" = "claude-docker: unknown flag '--bogus' (use -- to pass flags to claude)" ]
}

@test "parse_args: --help prints usage and exits 0" {
  run parse_args --help --bogus
  [ "$status" -eq 0 ]
  [[ "$output" == Usage:* ]]
  [[ "$output" != *"unknown flag"* ]]
}

@test "parse_args: flags, workspaces and passthrough after --" {
  parse_args --yolo --gh --ro a b -- --resume --bogus
  [ "$WITH_GH" = 1 ] && [ "$RO_WORKSPACES" = 1 ]
  [ "$(lines_of "${WORKSPACES[@]}")" = "$(printf 'a\nb')" ]
  [ "$(lines_of "${CLAUDE_FLAGS[@]}")" = "$(printf -- '--dangerously-skip-permissions\n--resume\n--bogus')" ]
}

@test "parse_args: workspace defaults to PWD" {
  cd "$WS"
  parse_args
  [ "${WORKSPACES[0]}" = "$WS" ]
}

@test "parse_args: --iterm and --tmux set CLAUDE_DOCKER_TMUX" {
  parse_args --iterm
  [ "$CLAUDE_DOCKER_TMUX" = cc ]
  parse_args --tmux
  [ "$CLAUDE_DOCKER_TMUX" = 1 ]
}

@test "parse_args: expands a leading ~/ in the config dir" {
  CLAUDE_CONFIG_DIR="~/cfg"
  parse_args
  [ "$CLAUDE_CONFIG_DIR" = "$HOME/cfg" ]
}

@test "parse_args: leaves ~user paths alone" {
  parse_args "--claude-dir=~alice/cfg"
  [ "$CLAUDE_CONFIG_DIR" = "~alice/cfg" ]
}

# --- validate_opts ---

@test "validate_opts: --gh with --gh-direct is rejected" {
  WITH_GH=1 WITH_GH_DIRECT=1
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"--gh and --gh-direct are mutually exclusive"* ]]
}

@test "validate_opts: --api without a token is rejected" {
  WITH_API=1 ANTHROPIC_API_KEY=""
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"--api needs ANTHROPIC_AUTH_TOKEN or ANTHROPIC_API_KEY"* ]]
}

@test "validate_opts: missing CLAUDE_DOCKER_AZ_CA is fatal" {
  WITH_AZ=1 CLAUDE_DOCKER_AZ_CA="$BATS_TEST_TMPDIR/nope.pem"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE_DOCKER_AZ_CA '$BATS_TEST_TMPDIR/nope.pem' is not a file"* ]]
}

@test "validate_opts: missing CLAUDE_DOCKER_GH_POLICY is fatal under --gh" {
  WITH_GH=1 CLAUDE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/nope.caddy"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE_DOCKER_GH_POLICY '$BATS_TEST_TMPDIR/nope.caddy' is not a readable file"* ]]
}

@test "validate_opts: a directory as CLAUDE_DOCKER_GH_POLICY is fatal" {
  WITH_GH=1 CLAUDE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR"
  run validate_opts
  [ "$status" -eq 1 ]
  [[ "$output" == *"is not a readable file"* ]]
}

@test "validate_opts: an unreadable CLAUDE_DOCKER_GH_POLICY is fatal" {
  [ "$(id -u)" != 0 ] || skip "root can read any file"
  WITH_GH=1 CLAUDE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/p.caddy"
  : >"$CLAUDE_DOCKER_GH_POLICY"
  chmod 000 "$CLAUDE_DOCKER_GH_POLICY"
  run validate_opts
  [ "$status" -eq 1 ]
}

@test "validate_opts: CLAUDE_DOCKER_GH_POLICY is ignored without --gh" {
  CLAUDE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/nope.caddy"
  run validate_opts
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# --- select_runtime ---

@test "select_runtime: CLAUDE_DOCKER_RUNTIME outside the allowlist is rejected" {
  CLAUDE_DOCKER_RUNTIME=evil
  run select_runtime
  [ "$status" -eq 1 ]
  [ "$output" = "claude-docker: CLAUDE_DOCKER_RUNTIME must be 'docker' or 'podman', got 'evil'" ]
}

@test "select_runtime: podman is accepted" {
  CLAUDE_DOCKER_RUNTIME=podman
  select_runtime
  [ "$RUNTIME" = podman ]
}

@test "select_runtime: auto-detect prefers docker" {
  RUNTIME=""
  select_runtime
  [ "$RUNTIME" = docker ]
}

@test "select_runtime: no engine on PATH fails" {
  unset -f docker podman
  PATH="$BATS_TEST_TMPDIR/empty" run select_runtime
  [ "$status" -eq 1 ]
  [[ "$output" == *"no container runtime found"* ]]
}

@test "select_runtime: requested engine missing from PATH fails" {
  unset -f podman
  CLAUDE_DOCKER_RUNTIME=podman
  PATH="$BATS_TEST_TMPDIR/empty" run select_runtime
  [ "$status" -eq 1 ]
  [[ "$output" == *"requested runtime 'podman' not found on PATH"* ]]
}

# --- prune_stale_gh ---

@test "prune_stale_gh: removes stopped sidecars and stale networks" {
  STUB_PS="old1 old2"
  prune_stale_gh
  grep -qx "docker rm -f old1" "$CALLS"
  grep -qx "docker rm -f old2" "$CALLS"
  grep -qx "docker network rm net1" "$CALLS"
}

@test "prune_stale_gh: failures never abort the run" {
  STUB_PS="old1" STUB_FAIL="rm ps network"
  run prune_stale_gh
  [ "$status" -eq 0 ]
}

# --- detect_msys / hostpath ---

@test "detect_msys: Git Bash disables argv path conversion" {
  uname() { echo MINGW64_NT-10.0; }
  detect_msys
  [ "$IS_MSYS" = 1 ]
  [ "$MSYS_NO_PATHCONV" = 1 ]
  [ "$MSYS2_ARG_CONV_EXCL" = '*' ]
}

@test "detect_msys: Linux leaves IS_MSYS off" {
  uname() { echo Linux; }
  detect_msys
  [ "$IS_MSYS" = 0 ]
}

@test "detect_msys: Git Bash uses UID 1000 and trusts only /workspaces" {
  uname() { echo MINGW64_NT-10.0; }
  detect_msys
  [ "$HOST_UID" = 1000 ] && [ "$HOST_GID" = 1000 ]
  build_git_config
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *$'GIT_CONFIG_KEY_0=safe.directory\n-e\nGIT_CONFIG_VALUE_0=/workspaces/*'* ]]
}

@test "detect_msys: Linux keeps id -u and adds no git config" {
  uname() { echo Linux; }
  detect_msys
  [ "$HOST_UID" = "$(id -u)" ] && [ "$HOST_GID" = "$(id -g)" ]
  build_git_config
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GIT_CONFIG_* ]]
}

@test "hostpath: identity off MSYS" {
  run hostpath "/c/Users/me dir"
  [ "$output" = "/c/Users/me dir" ]
}

@test "hostpath: cygpath -m under MSYS" {
  IS_MSYS=1
  cygpath() { echo "cygpath $*"; }
  run hostpath /c/Users/me
  [ "$output" = "cygpath -m /c/Users/me" ]
}

# --- build_workspace_mounts ---

@test "build_workspace_mounts: mounts each workspace and sets CWD" {
  mkdir -p "$BATS_TEST_TMPDIR/other"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/other") RO_WORKSPACES=1
  build_workspace_mounts
  [ "$CWD" = /workspaces/repo ]
  [ "$(lines_of "${MOUNT_ARGS[@]}")" = "$(printf -- '-v\n%s:/workspaces/repo:ro\n-v\n%s:/workspaces/other:ro' "$WS" "$BATS_TEST_TMPDIR/other")" ]
}

@test "build_workspace_mounts: a missing workspace gets a prefixed error" {
  WORKSPACES=("$BATS_TEST_TMPDIR/missing")
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [ "$output" = "claude-docker: workspace '$BATS_TEST_TMPDIR/missing' is not a directory" ]
}

@test "build_workspace_mounts: / is rejected" {
  WORKSPACES=(/)
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace '/' is the filesystem root"* ]]
}

@test "build_workspace_mounts: a ':' in the basename is rejected" {
  mkdir -p "$BATS_TEST_TMPDIR/a:b"
  WORKSPACES=("$BATS_TEST_TMPDIR/a:b")
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"basename 'a:b' cannot contain ':'"* ]]
}

@test "build_workspace_mounts: basename collisions are rejected" {
  mkdir -p "$BATS_TEST_TMPDIR/x/repo"
  WORKSPACES=("$WS" "$BATS_TEST_TMPDIR/x/repo")
  run build_workspace_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"workspace basename collision"* ]]
}

# --- build_cred_mounts ---

@test "build_cred_mounts: --aws mounts config and sso read-only" {
  mkdir -p "$HOME/.aws/sso"
  : >"$HOME/.aws/config"
  WITH_AWS=1
  build_cred_mounts
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$HOME/.aws/config:/root/.aws/config:ro"* ]]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$HOME/.aws/sso:/root/.aws/sso:ro"* ]]
}

@test "build_cred_mounts: --registry honours a relocated npmrc" {
  npm_config_userconfig="$BATS_TEST_TMPDIR/npmrc"
  : >"$npm_config_userconfig"
  WITH_REGISTRY=1
  build_cred_mounts
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$BATS_TEST_TMPDIR/npmrc:/root/.npmrc:ro"* ]]
}

@test "build_cred_mounts: a missing CLAUDE_DOCKER_API_CA is fatal" {
  WITH_API=1 CLAUDE_DOCKER_API_CA="$BATS_TEST_TMPDIR/nope.pem"
  run build_cred_mounts
  [ "$status" -eq 1 ]
  [[ "$output" == *"CLAUDE_DOCKER_API_CA '$BATS_TEST_TMPDIR/nope.pem' is not a file"* ]]
}

# --- build_env_args ---

@test "build_env_args: forwards set opt-in vars by name only" {
  WITH_AWS=1
  export AWS_PROFILE=dev AWS_REGION=""
  build_env_args
  [ "$(lines_of "${ENV_ARGS[@]}")" = "$(printf -- '-e\nTERM\n-e\nCOLORTERM\n-e\nAWS_PROFILE')" ]
}

@test "build_env_args: UV_INDEX scan forwards only non-empty _USERNAME/_PASSWORD" {
  WITH_REGISTRY=1
  export UV_INDEX_CORP_PASSWORD=secret UV_INDEX_CORP_USERNAME="" UV_CACHE_DIR=/host/cache UV_INDEX_CORP_URL=https://x
  build_env_args
  local got
  got=$(lines_of "${ENV_ARGS[@]}")
  [[ "$got" == *UV_INDEX_CORP_PASSWORD* ]]
  [[ "$got" != *UV_INDEX_CORP_USERNAME* ]]
  [[ "$got" != *UV_CACHE_DIR* ]]
  [[ "$got" != *UV_INDEX_CORP_URL* ]]
}

@test "build_env_args: the UV_INDEX scan is off without --registry" {
  export UV_INDEX_CORP_PASSWORD=secret
  build_env_args
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *UV_INDEX_CORP_PASSWORD* ]]
}

# --- discover_tokens ---

@test "discover_tokens: --gh-direct forwards the gh CLI token by name" {
  WITH_GH_DIRECT=1
  discover_tokens
  [ "$GH_TOKEN" = gho_stub ]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *$'-e\nGH_TOKEN'* ]]
}

@test "discover_tokens: --gh keeps the token out of the agent env" {
  WITH_GH=1
  discover_tokens
  [ "$GH_HOST_TOKEN" = gho_stub ]
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GH_TOKEN* ]]
}

@test "discover_tokens: host GH_TOKEN wins over the gh CLI" {
  WITH_GH=1 GH_TOKEN=from_env
  discover_tokens
  [ "$GH_HOST_TOKEN" = from_env ]
  run ! grep -q "^gh " "$CALLS"
}

@test "discover_tokens: no gh flag means no gh call" {
  discover_tokens
  [ -z "$GH_HOST_TOKEN" ]
  run ! grep -q "^gh " "$CALLS"
}

@test "discover_tokens: --glab asks glab for GITLAB_HOST's token" {
  WITH_GLAB=1 GITLAB_HOST=https://gitlab.example.com/
  SEEN_PATHS=("$WS")
  discover_tokens
  [ "$GITLAB_TOKEN" = glpat_stub ]
  grep -q "glab config get token --host gitlab.example.com" "$CALLS"
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *$'-e\nGITLAB_TOKEN'* ]]
}

@test "discover_tokens: --glab with no token warns" {
  glab() { return 0; }
  WITH_GLAB=1 GITLAB_HOST=gitlab.example.com
  SEEN_PATHS=("$WS")
  run discover_tokens
  [ "$status" -eq 0 ]
  [[ "$output" == *"--glab: no GitLab token found for gitlab.example.com"* ]]
}

# --- build_git_config ---

@test "build_git_config: without --git-https adds nothing" {
  WITH_GLAB=1 WITH_GH=1 GITLAB_HOST=gitlab.example.com
  build_git_config
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GIT_CONFIG_* ]]
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GLAB_GIT_PROTOCOL* ]]
}

@test "build_git_config: --git-https rewrites and authenticates per forge" {
  WITH_GIT_HTTPS=1 WITH_GH_DIRECT=1 WITH_GLAB=1 WITH_AZ=1
  GITLAB_HOST=https://gitlab.example.com:8443/ AZURE_DEVOPS_ORG_URL=https://dev.azure.com/org
  GIT_CFG=(safe.directory "/workspaces/*")
  build_git_config
  env=$(lines_of "${ENV_ARGS[@]}")
  [[ "$env" == *$'GIT_CONFIG_KEY_0=safe.directory\n-e\nGIT_CONFIG_VALUE_0=/workspaces/*'* ]]
  [[ "$env" == *$'GIT_CONFIG_KEY_1=url.https://github.com/.insteadOf\n-e\nGIT_CONFIG_VALUE_1=git@github.com:'* ]]
  [[ "$env" == *"GIT_CONFIG_VALUE_3=!gh auth git-credential"* ]]
  [[ "$env" == *$'GIT_CONFIG_KEY_4=url.https://gitlab.example.com:8443/.insteadOf\n-e\nGIT_CONFIG_VALUE_4=git@gitlab.example.com:'* ]]
  [[ "$env" == *$'GIT_CONFIG_KEY_6=credential.https://gitlab.example.com:8443.helper\n-e\nGIT_CONFIG_VALUE_6=!glab auth git-credential'* ]]
  [[ "$env" == *"GIT_CONFIG_KEY_7=credential.https://dev.azure.com.helper"* ]]
  [[ "$env" == *'password=$AZURE_DEVOPS_EXT_PAT'* ]]
  [[ "$env" == *"GIT_CONFIG_COUNT=8"* ]]
  [[ "$env" == *"GLAB_GIT_PROTOCOL=https"* ]]
}

@test "build_git_config: --git-https rewrites git for real" {
  unset -f git
  WITH_GIT_HTTPS=1 WITH_GLAB=1 GITLAB_HOST=gitlab.example.com
  build_git_config
  # ENV_ARGS is (-e K=V)...: export every K=V and ask git for the rewritten URL.
  for a in "${ENV_ARGS[@]}"; do [ "$a" = -e ] || export "$a"; done
  run git ls-remote --get-url git@gitlab.example.com:grp/repo.git
  [ "$output" = https://gitlab.example.com/grp/repo.git ]
}

@test "build_git_config: --git-https rewrites Azure DevOps SSH remotes per project / collection" {
  unset -f git
  git init -q "$WS" && git -C "$WS" remote add origin git@ssh.dev.azure.com:v3/org/proj/repo
  srv="$BATS_TEST_TMPDIR/srv"
  git init -q "$srv" && git -C "$srv" remote add origin ssh://ado.example.com:22/tfs/Coll/Proj/_git/repo
  SEEN_PATHS=("$WS" "$srv")
  WITH_GIT_HTTPS=1 WITH_AZ=1 AZURE_DEVOPS_ORG_URL=https://dev.azure.com/org
  build_git_config
  for a in "${ENV_ARGS[@]}"; do [ "$a" = -e ] || export "$a"; done
  # Services: any repo of the remote's project, either SSH form.
  [ "$(git ls-remote --get-url git@ssh.dev.azure.com:v3/org/proj/other)" = https://dev.azure.com/org/proj/_git/other ]
  [ "$(git ls-remote --get-url ssh://git@ssh.dev.azure.com/v3/org/proj/other)" = https://dev.azure.com/org/proj/_git/other ]
  # No PAT helper for the Server host, so its remote is left alone.
  [ "$(git ls-remote --get-url ssh://ado.example.com:22/tfs/Coll/Proj/_git/repo)" = ssh://ado.example.com:22/tfs/Coll/Proj/_git/repo ]

  GIT_CFG=() ENV_ARGS=()
  unset "${!GIT_CONFIG_@}"
  AZURE_DEVOPS_ORG_URL=https://ado.example.com/tfs/Coll/
  build_git_config
  for a in "${ENV_ARGS[@]}"; do [ "$a" = -e ] || export "$a"; done
  # Server: any repo of the collection; other hosts and Services left alone.
  [ "$(git ls-remote --get-url ssh://ado.example.com:22/tfs/Coll/Proj2/_git/r)" = https://ado.example.com/tfs/Coll/Proj2/_git/r ]
  [ "$(git ls-remote --get-url ssh://other.example.com:22/tfs/Coll/Proj/_git/r)" = ssh://other.example.com:22/tfs/Coll/Proj/_git/r ]
  [ "$(git ls-remote --get-url git@ssh.dev.azure.com:v3/org/proj/repo)" = git@ssh.dev.azure.com:v3/org/proj/repo ]
}

@test "build_git_config: --git-https alone warns" {
  WITH_GIT_HTTPS=1
  run build_git_config
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to rewrite"* ]]
}

# --- forward_git_identity / build_flags_env ---

@test "forward_git_identity: forwards name and email" {
  forward_git_identity
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"GIT_AUTHOR_NAME=Ada Lovelace"* ]]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"GIT_COMMITTER_EMAIL=ada@example.com"* ]]
}

@test "forward_git_identity: unset identity forwards nothing" {
  git() { return 1; }
  forward_git_identity
  [[ "$(lines_of "${ENV_ARGS[@]}")" != *GIT_* ]]
}

@test "build_flags_env: tags the opt-ins in README order" {
  WITH_AWS=1 WITH_GH=1 EPHEMERAL=1
  build_flags_env
  [ "${ENV_ARGS[*]: -1}" = "CLAUDE_DOCKER_FLAGS=gh,aws,ephemeral" ]
}

@test "build_flags_env: no opt-ins, no tag" {
  build_flags_env
  [[ "${ENV_ARGS[*]}" != *CLAUDE_DOCKER_FLAGS* ]]
}

# --- create_stage ---

@test "create_stage: stage dir under HOME, removed by the EXIT trap" {
  (
    create_stage
    echo "$stage" >"$BATS_TEST_TMPDIR/stage"
    [ -d "$stage" ]
    [ "$GH_PROXY_SIDECAR" = "claude-gh-proxy-${stage##*.}" ]
  )
  local s
  s=$(cat "$BATS_TEST_TMPDIR/stage")
  [[ "$s" == "$HOME/.cache/claude-docker/host."* ]]
  [ ! -e "$s" ]
  grep -q "docker rm -f claude-gh-proxy-" "$CALLS"
  grep -q "docker network rm claude-gh-" "$CALLS"
}

@test "create_stage: an unwritable cache dir aborts" {
  : >"$HOME/.cache"
  run create_stage
  [ "$status" -eq 1 ]
}

# --- start_gh_sidecar ---

sidecar_setup() {
  WITH_GH=1 GH_HOST_TOKEN=gho_secret
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage"
  GH_PROXY_NETWORK=claude-gh-x GH_PROXY_SIDECAR=claude-gh-proxy-x
}

@test "start_gh_sidecar: no-op without a host token" {
  WITH_GH=1
  start_gh_sidecar
  [ "$GH_SIDECAR_ACTIVE" = 0 ]
  [ ! -s "$CALLS" ]
}

@test "start_gh_sidecar: wires the agent to the sidecar" {
  sidecar_setup
  CLAUDE_DOCKER_GH_POLICY="$BATS_TEST_TMPDIR/policy.caddy"
  echo "# user policy" >"$CLAUDE_DOCKER_GH_POLICY"
  start_gh_sidecar 2>/dev/null
  [ "$GH_SIDECAR_ACTIVE" = 1 ]
  [ "$(cat "$stage/gh-proxy/policy.caddy")" = "# user policy" ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *$'--add-host\napi.github.com:10.0.0.2'* ]]
  [[ "$(lines_of "${ENV_ARGS[@]}")" == *"GH_TOKEN=claude-docker-proxy"* ]]
  # The real token is passed by name, never on argv.
  run ! grep -q gho_secret "$CALLS"
  run ! grep -rq gho_secret "$stage"
}

@test "start_gh_sidecar: no policy stages an empty one" {
  sidecar_setup
  start_gh_sidecar 2>/dev/null
  [ -f "$stage/gh-proxy/policy.caddy" ] && [ ! -s "$stage/gh-proxy/policy.caddy" ]
}

@test "start_gh_sidecar: network create failure aborts" {
  sidecar_setup
  STUB_FAIL="network"
  run start_gh_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to create network 'claude-gh-x'"* ]]
  run ! grep -q "^docker run" "$CALLS"
}

@test "start_gh_sidecar: sidecar start failure aborts" {
  sidecar_setup
  STUB_FAIL="run"
  run start_gh_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"failed to start the gh-auth-proxy sidecar"* ]]
  run ! grep -q "^docker cp" "$CALLS"
}

@test "start_gh_sidecar: an exited sidecar reports Caddy's logs" {
  sidecar_setup
  STUB_FAIL="cp" STUB_ALIVE=""
  run start_gh_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"sidecar exited during startup"* ]]
  [[ "$output" == *"  | caddy: bad policy"* ]]
  run ! grep -q "^docker inspect" "$CALLS"
}

@test "start_gh_sidecar: no CA within the budget aborts" {
  sidecar_setup
  STUB_FAIL="cp"
  run start_gh_sidecar
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not produce a CA certificate within 15s"* ]]
  [ "$(grep -c "^docker cp" "$CALLS")" -eq 15 ]
}

@test "start_gh_sidecar: a failing inspect reaches the address error" {
  STUB_FAIL="inspect"
  # Under set -e, which `run` would ignore: without `|| true` on the inspect
  # the shell aborts before this message prints.
  run_script_fn 'WITH_GH=1 GH_HOST_TOKEN=t stage=$HOME/st; mkdir -p "$stage"; start_gh_sidecar'
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not determine the gh-auth-proxy sidecar's network address"* ]]
  [[ "$output" != *"is active"* ]]
}

# --- stage_host_config ---

@test "stage_host_config: follows a symlink chain to the real dir" {
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$stage" "$BATS_TEST_TMPDIR/real/skills"
  echo hi >"$BATS_TEST_TMPDIR/real/skills/s.md"
  ln -s real/skills "$BATS_TEST_TMPDIR/hop"
  ln -s ../hop "$CLAUDE_CONFIG_DIR/skills"
  stage_host_config
  [ "$(cat "$stage/skills/s.md")" = hi ]
  [ ! -L "$stage/skills" ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$stage/skills:/root/.claude/skills:ro"* ]]
}

@test "stage_host_config: a symlink cycle is skipped, not looped on" {
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$stage"
  ln -s agents2 "$CLAUDE_CONFIG_DIR/agents"
  ln -s agents "$CLAUDE_CONFIG_DIR/agents2"
  run stage_host_config
  [ "$status" -eq 0 ]
  [ ! -e "$stage/agents" ]
}

# Run the generated statusline wrapper against a host script at $1.
run_statusline() {
  sed "s#/root/.claude/statusline-command.original.sh#$1#" "$stage/statusline-command.sh" >"$BATS_TEST_TMPDIR/wrap.sh"
  chmod +x "$BATS_TEST_TMPDIR/wrap.sh"
  run sh -c 'echo "{}" | "$1"' _ "$BATS_TEST_TMPDIR/wrap.sh"
}

@test "stage_host_config: statusline wrapper prefixes the flag tag" {
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$stage"
  printf '#!/bin/sh\ncat >/dev/null; printf body\n' >"$CLAUDE_CONFIG_DIR/statusline-command.sh"
  chmod +x "$CLAUDE_CONFIG_DIR/statusline-command.sh"
  stage_host_config
  [ -x "$stage/statusline-command.sh" ]
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"statusline-command.sh:/root/.claude/statusline-command.original.sh:ro"* ]]
  CLAUDE_DOCKER_FLAGS=gh,aws run_statusline "$CLAUDE_CONFIG_DIR/statusline-command.sh"
  [ "$output" = $'\033[33mdocker:gh,aws\033[0m body' ]
  run_statusline "$CLAUDE_CONFIG_DIR/statusline-command.sh"
  [ "$output" = body ]
}

@test "stage_host_config: a non-executable statusline falls back to bash" {
  CLAUDE_CONFIG_DIR="$BATS_TEST_TMPDIR/cfg"
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$CLAUDE_CONFIG_DIR" "$stage"
  printf 'cat >/dev/null; echo "${BASH_VERSION:+bash}"\n' >"$CLAUDE_CONFIG_DIR/statusline-command.sh"
  chmod 644 "$CLAUDE_CONFIG_DIR/statusline-command.sh"
  stage_host_config
  run_statusline "$CLAUDE_CONFIG_DIR/statusline-command.sh"
  [ "$output" = bash ]
}

# --- stage_git_overlays ---

@test "stage_git_overlays: overlays a real .git/config" {
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$WS/.git"
  echo "[core]" >"$WS/.git/config"
  SEEN_NAMES=(repo) SEEN_PATHS=("$WS")
  stage_git_overlays
  grep -q "relativeWorktrees = true" "$stage/git-config-repo"
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *"$stage/git-config-repo:/workspaces/repo/.git/config"* ]]
}

@test "stage_git_overlays: a symlinked .git/config is skipped" {
  stage="$BATS_TEST_TMPDIR/stage"
  mkdir -p "$stage" "$WS/.git"
  ln -s /etc/hostname "$WS/.git/config"
  SEEN_NAMES=(repo) SEEN_PATHS=("$WS")
  stage_git_overlays
  [ ! -e "$stage/git-config-repo" ]
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

# --- build_cmd ---

@test "build_cmd: extra workspaces become --add-dir" {
  CONTAINER_PATHS=(/workspaces/a /workspaces/b) CLAUDE_FLAGS=(--resume)
  build_cmd
  [ "${CMD[*]}" = "claude --add-dir /workspaces/b --resume" ]
}

@test "build_cmd: CLAUDE_DOCKER_TMUX=1 wraps in plain tmux" {
  CONTAINER_PATHS=(/workspaces/a) CLAUDE_DOCKER_TMUX=1
  build_cmd
  [ "${CMD[*]:0:6}" = "tmux -u new-session -A -s claude" ]
  [ "${CMD[*]: -1}" = claude ]
}

@test "build_cmd: CLAUDE_DOCKER_TMUX=cc uses control mode" {
  CONTAINER_PATHS=(/workspaces/a) CLAUDE_DOCKER_TMUX=cc
  build_cmd
  [ "${CMD[*]:0:3}" = "tmux -u -CC" ]
}

@test "build_cmd: the tmux hold keeps a non-zero exit visible" {
  CONTAINER_PATHS=(/workspaces/a) CLAUDE_DOCKER_TMUX=1 CLAUDE_FLAGS=()
  build_cmd
  # CMD[7..] is: sh -c HOLD_ON_ERR _ claude; run it with `false` as claude.
  run sh -c "${CMD[8]}" _ false </dev/null
  [ "$status" -eq 1 ]
  [[ "$output" == *"[false exited 1"* ]]
}

# --- build_volume_mounts ---

@test "build_volume_mounts: --ephemeral mounts no volumes or masks" {
  EPHEMERAL=1
  build_volume_mounts
  [ "${#MOUNT_ARGS[@]}" -eq 0 ]
}

@test "build_volume_mounts: masks every credential dir with no opt-ins" {
  build_volume_mounts
  [ "${MOUNT_ARGS[*]:0:4}" = "-v claude-code-root:/root -v claude-code-home:/root/.claude" ]
  local got
  got=$(lines_of "${MOUNT_ARGS[@]}")
  for p in /root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.azure /root/.aws; do
    [[ "$got" == *$'--tmpfs\n'"$p"$'\n'* || "$got" == *$'--tmpfs\n'"$p" ]]
  done
}

@test "build_volume_mounts: gh stays masked while the sidecar is active" {
  WITH_GH=1 GH_SIDECAR_ACTIVE=1
  build_volume_mounts
  [[ "$(lines_of "${MOUNT_ARGS[@]}")" == *$'--tmpfs\n/root/.config/gh'* ]]
}

# --- run_container / main ---

@test "run_container: hands everything to the runtime" {
  MOUNT_ARGS=(-v a:b) ENV_ARGS=(-e TERM) CWD=/workspaces/repo CMD=(claude)
  run_container
  grep -q "^docker run --rm -it --init .* -v a:b -e TERM -w /workspaces/repo claude-code:local claude$" "$CALLS"
}

@test "main: end to end with stubs" {
  run_script --ephemeral --aws "$WS" -- --resume
  [ "$status" -eq 0 ]
  grep -q "^docker run --rm -it .*-v $WS:/workspaces/repo .*CLAUDE_DOCKER_FLAGS=aws,ephemeral -w /workspaces/repo claude-code:local claude --resume$" "$CALLS"
}

@test "main: a bad workspace stops before any docker call" {
  run_script "$BATS_TEST_TMPDIR/missing"
  [ "$status" -eq 1 ]
  [ "$output" = "claude-docker: workspace '$BATS_TEST_TMPDIR/missing' is not a directory" ]
  run ! grep -q "^docker run" "$CALLS"
}

@test "main: a failing sidecar stops before the agent starts" {
  STUB_FAIL="inspect"
  run_script --ephemeral --gh "$WS"
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not determine"* ]]
  run ! grep -q "^docker run --rm" "$CALLS"
}
