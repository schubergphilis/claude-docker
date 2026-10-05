#!/usr/bin/env bats
# Unit tests for smoke/smoke.sh; docker, openssl, stat and id are stubbed, so
# no daemon is needed. The real matrix runs in ci.yml's docker-build job.

setup() {
  unset HOST_UID HOST_GID IMAGE
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
  # shellcheck source=../../smoke/smoke.sh
  source "${BATS_TEST_DIRNAME}/../../smoke/smoke.sh"

  DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  PROBE=content   # content | empty | none: what the fake container leaves behind
  STUB_STDERR=""  # what the fake container writes to stderr
  DOCKER_RC=0
  STAT_UID=1000   # empty = both stat calls fail
  # One line per `docker run`: the settings env, the sentinel, and the seeded
  # fixture's content (or "no-seed" when the seed mount is absent).
  docker() {
    local arg prev="" ws="" seed="no-seed" mode="" sentinel=""
    [ "$1" = run ] || return 0
    for arg in "$@"; do
      if [ "$prev" = -v ]; then
        case "$arg" in
          *:/workspaces/smoke*) ws="${arg%%:/workspaces/smoke*}" ;;
          *:/run/claude-docker/settings.json:ro) seed="$(cat "${arg%%:*}")" ;;
        esac
      fi
      case "$arg" in
        EXPECT_SETTINGS=*) mode="${arg#*=}" ;;
        EXPECT_SETTINGS_SENTINEL=*) sentinel="${arg#*=}" ;;
      esac
      prev="$arg"
    done
    echo "mode=${mode} sentinel=${sentinel} seed=${seed}" >> "$DOCKER_LOG"
    case "$PROBE" in
      content) echo probe > "${ws}/smoke-probe.txt" ;;
      empty) : > "${ws}/smoke-probe.txt" ;;
    esac
    printf '%s' "$STUB_STDERR" >&2
    return "$DOCKER_RC"
  }
  openssl() { touch "${CREDS_HOST}/api-ca.crt"; }
  stat() { [ -n "$STAT_UID" ] && echo "$STAT_UID"; }
  id() { echo 1000; }
}

# Print only the tmpfs mask paths from VOLUME_ARGS, space-separated.
masks() {
  local i out=""
  for ((i = 0; i < ${#VOLUME_ARGS[@]}; i++)); do
    [ "${VOLUME_ARGS[i]}" = --tmpfs ] && out+="${VOLUME_ARGS[i + 1]} "
  done
  echo "${out% }"
}

# --- argument parsing ------------------------------------------------------

@test "defaults come from id and IMAGE" {
  IMAGE=img:tag
  parse_args
  [ "$HOST_UID_ARG" = 1000 ] && [ "$HOST_GID_ARG" = 1000 ]
  [ "$VOLSTATE" = cold ] && [ "$RO" = 0 ] && [ "$EPHEMERAL" = 0 ] && [ "$SETTINGS" = 1 ]
  [ "$OPTINS" = "" ] && [ "$IMAGE" = img:tag ]
}

@test "HOST_UID/HOST_GID env override id" {
  HOST_UID=501 HOST_GID=20 parse_args
  [ "$HOST_UID_ARG" = 501 ] && [ "$HOST_GID_ARG" = 20 ]
}

@test "every flag is parsed" {
  parse_args --uid=501 --gid=20 --optins=aws,glab --volstate=warm --ro=1 \
    --ephemeral=1 --settings=0 --image=x:y
  [ "$HOST_UID_ARG" = 501 ] && [ "$HOST_GID_ARG" = 20 ] && [ "$OPTINS" = aws,glab ]
  [ "$VOLSTATE" = warm ] && [ "$RO" = 1 ] && [ "$EPHEMERAL" = 1 ]
  [ "$SETTINGS" = 0 ] && [ "$IMAGE" = x:y ]
}

@test "unknown flag is rejected" {
  run parse_args --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument '--bogus'"* ]]
}

@test "bad flag values are rejected" {
  local bad
  for bad in --ro=yes --ephemeral=true --settings=2 --volstate=wram \
             --uid=abc --uid= --gid=1x; do
    run parse_args "$bad"
    [ "$status" -eq 1 ] || { echo "accepted: $bad"; return 1; }
    [[ "$output" == *FAIL:* ]]
  done
}

# --- opt-in parsing --------------------------------------------------------

@test "no opt-ins leaves every WITH_ flag off" {
  OPTINS=""
  parse_optins
  [ "$WITH_AWS$WITH_GLAB$WITH_TFE$WITH_API$WITH_AZ" = 00000 ]
}

@test "every opt-in is parsed" {
  OPTINS=aws,glab,tfe,api,az
  parse_optins
  [ "$WITH_AWS$WITH_GLAB$WITH_TFE$WITH_API$WITH_AZ" = 11111 ]
}

@test "unknown opt-in is rejected" {
  OPTINS=aws,gh
  run parse_optins
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown opt-in: 'gh'"* ]]
}

@test "opt-ins are not glob-expanded" {
  touch "${BATS_TEST_TMPDIR}/aws"
  cd "$BATS_TEST_TMPDIR"
  OPTINS='a*'
  run parse_optins
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown opt-in: 'a*'"* ]]
}

# --- masks -----------------------------------------------------------------

volume_state() {
  EPHEMERAL=$1 VOLSTATE=$2 WITH_AWS=$3 WITH_GLAB=$4 WITH_TFE=$5 WITH_AZ=$6
  VOL_NAME=""
  build_volume_args
}

@test "cold, no opt-ins: anonymous volumes and every mask" {
  volume_state 0 cold 0 0 0 0
  [ "${VOLUME_ARGS[*]:0:4}" = "-v /root -v /root/.claude" ]
  [ "$(masks)" = "/root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.azure /root/.aws" ]
}

@test "each opt-in drops its own mask; aws narrows to the cli cache" {
  volume_state 0 cold 1 0 0 0
  [ "$(masks)" = "/root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.azure /root/.aws/cli/cache" ]
  volume_state 0 cold 0 1 0 0
  [ "$(masks)" = "/root/.config/gh /root/.terraform.d /root/.azure /root/.aws" ]
  volume_state 0 cold 0 0 1 0
  [ "$(masks)" = "/root/.config/gh /root/.config/glab-cli /root/.azure /root/.aws" ]
  volume_state 0 cold 0 0 0 1
  [ "$(masks)" = "/root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.aws" ]
  volume_state 0 cold 1 1 1 1
  [ "$(masks)" = "/root/.config/gh /root/.aws/cli/cache" ]
}

@test "warm uses named volumes" {
  volume_state 0 warm 0 0 0 0
  [ "$VOL_NAME" = "smoke-test-root-$$" ]
  [ "${VOLUME_ARGS[*]:0:4}" = "-v ${VOL_NAME}:/root -v ${VOL_NAME}-claude:/root/.claude" ]
  [ "$(masks)" = "/root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.azure /root/.aws" ]
}

@test "ephemeral mounts no volumes and no masks" {
  volume_state 1 warm 0 0 0 0
  [ "${#VOLUME_ARGS[@]}" -eq 0 ]
  [ "$VOL_NAME" = "" ]
}

# --- run args --------------------------------------------------------------

run_args_state() {
  TMPROOT="$BATS_TEST_TMPDIR"
  WORKSPACE_HOST="${TMPROOT}/workspace" CREDS_HOST="${TMPROOT}/creds"
  # shellcheck disable=SC2034  # read by build_run_args
  SETTINGS_FIXTURE="${TMPROOT}/settings.docker.json"
  mkdir -p "$WORKSPACE_HOST" "$CREDS_HOST"
  parse_args "$@"
  parse_optins
  build_run_args
}

@test "RO=1 mounts the workspace :ro" {
  run_args_state --ro=1
  [ "${MOUNT_ARGS[*]}" = "-v ${WORKSPACE_HOST}:/workspaces/smoke:ro" ]
  run_args_state --ro=0
  [ "${MOUNT_ARGS[*]}" = "-v ${WORKSPACE_HOST}:/workspaces/smoke" ]
}

@test "opt-ins add their credential mounts and env" {
  run_args_state --optins=aws,glab,tfe,api,az
  [[ "${MOUNT_ARGS[*]}" == *":/root/.aws/config:ro"* ]]
  [[ "${MOUNT_ARGS[*]}" == *":/root/.config/glab-cli:ro"* ]]
  [[ "${MOUNT_ARGS[*]}" == *":/root/.terraform.d/credentials.tfrc.json:ro"* ]]
  [[ "${MOUNT_ARGS[*]}" == *":/usr/local/share/ca-certificates/claude-docker-api.crt:ro"* ]]
  [[ "${ENV_ARGS[*]}" == *"AZURE_DEVOPS_EXT_PAT=SMOKE-SENTINEL-AZ"* ]]
}

@test "settings=0 mounts no seed" {
  run_args_state --settings=0
  [ "${#SETTINGS_MOUNT_ARGS[@]}" -eq 0 ]
  [ "$EXPECT_SETTINGS_MODE" = 0 ]
}

# --- end to end through main -----------------------------------------------

@test "cold cell passes and cleans up its temp dir" {
  run main --volstate=cold
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cell PASS"* ]]
  [ "$(cat "$DOCKER_LOG")" = "mode=1 sentinel=SMOKE-SENTINEL-SETTINGS seed={\"env\":{\"SMOKE_SENTINEL\":\"SMOKE-SENTINEL-SETTINGS\"}}" ]
  [ -z "$(ls -A "${HOME}/.cache/claude-docker")" ]
}

@test "warm cell runs cold, re-seeded warm, then no-seed passes" {
  run main --volstate=warm
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = 'mode=1 sentinel=SMOKE-SENTINEL-SETTINGS seed={"env":{"SMOKE_SENTINEL":"SMOKE-SENTINEL-SETTINGS"}}
mode=1 sentinel=SMOKE-SENTINEL-SETTINGS-V2 seed={"env":{"SMOKE_SENTINEL":"SMOKE-SENTINEL-SETTINGS-V2"}}
mode=keep sentinel=SMOKE-SENTINEL-SETTINGS-V2 seed=no-seed' ]
}

@test "warm cell with settings=0 runs two no-seed passes" {
  run main --volstate=warm --settings=0
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = 'mode=0 sentinel=SMOKE-SENTINEL-SETTINGS seed=no-seed
mode=0 sentinel=SMOKE-SENTINEL-SETTINGS seed=no-seed' ]
}

@test "container failure fails the cell" {
  DOCKER_RC=3
  run main
  [ "$status" -eq 3 ]
  [[ "$output" != *"host-side"* ]]
}

@test "a failed warm pass stops the sequence" {
  DOCKER_RC=3
  run main --volstate=warm
  [ "$status" -eq 3 ]
  [ "$(wc -l < "$DOCKER_LOG")" -eq 1 ]
  [[ "$output" != *"running warm pass"* ]]
}

@test "a failed setup step stops before any container runs" {
  mktemp() { return 4; }
  run main
  [ "$status" -eq 4 ]
  [ ! -e "$DOCKER_LOG" ]
  [[ "$output" != *"Cell:"* ]]
}

@test "missing probe file fails" {
  PROBE=none
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: host-side: probe file not created"* ]]
}

@test "empty probe file fails" {
  PROBE=empty
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: host-side: probe file is empty"* ]]
}

@test "wrong probe owner fails" {
  STAT_UID=4242
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: host-side: probe file owned by 4242, expected 1000"* ]]
}

@test "unreadable probe owner fails with a message" {
  STAT_UID=""
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: host-side: could not stat probe file owner"* ]]
}

@test "entrypoint WARN on stderr fails" {
  STUB_STDERR="entrypoint: WARN chown failed"
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL: host-side: unexpected 'entrypoint: WARN'"* ]]
}

@test "RO=1 skips the probe checks" {
  PROBE=none STAT_UID=""
  run main --ro=1
  [ "$status" -eq 0 ]
  [[ "$output" != *"probe file"* ]]
}

@test "uid=0 skips the ownership check" {
  STAT_UID=""
  run main --uid=0
  [ "$status" -eq 0 ]
  [[ "$output" != *"owned by"* ]]
}
