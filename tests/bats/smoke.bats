#!/usr/bin/env bats
# Unit tests for smoke/smoke.sh; docker, openssl, stat, id and run.sh are
# stubbed, so no daemon is needed. The real matrix runs in ci.yml's
# docker-build job.
# Globals set here are read by the sourced smoke.sh functions (SC2034).
# shellcheck disable=SC2034

setup() {
  unset HOST_UID HOST_GID IMAGE DOCKER_HOST DOCKER_CONTEXT
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
  # shellcheck source=../../smoke/smoke.sh
  source "${BATS_TEST_DIRNAME}/../../smoke/smoke.sh"
  id() { echo 1000; }
  openssl() { touch "${FAKE_HOME}/api-ca.crt"; }
  STAT_UID=1000   # empty = both stat calls fail
  stat() { [ -n "$STAT_UID" ] && echo "$STAT_UID"; }
}

# A fake `docker` binary on PATH (the shim execs it by path, so a function
# won't do) that logs its argv one per line.
fake_docker_bin() {
  mkdir -p "${BATS_TEST_TMPDIR}/realbin"
  cat > "${BATS_TEST_TMPDIR}/realbin/docker" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${BATS_TEST_TMPDIR}/docker.argv"
EOF
  chmod +x "${BATS_TEST_TMPDIR}/realbin/docker"
  PATH="${BATS_TEST_TMPDIR}/realbin:$PATH"
}

# Parse args and build the workspace, with a fake run.sh that plays the
# container: it records its argv and env, writes the probe file, and replays
# fake.stderr / fake.rc.
setup_cell() {
  parse_args "$@"
  # Keep bats' own EXIT trap: the temp dir sits under BATS_TEST_TMPDIR anyway.
  trap() { :; }
  setup_workspace
  unset -f trap
  RUN_SH="${BATS_TEST_TMPDIR}/fake-run.sh"
  cat > "$RUN_SH" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${BATS_TEST_TMPDIR}/run.argv"
env > "${BATS_TEST_TMPDIR}/run.env"
ws="\${!#}"
echo probe > "\$ws/smoke-probe.txt"
cat "${BATS_TEST_TMPDIR}/fake.stderr" >&2 2>/dev/null
exit "\$(cat "${BATS_TEST_TMPDIR}/fake.rc" 2>/dev/null || echo 0)"
EOF
  fake_docker_bin
  write_docker_shim
  setup_settings
  parse_optins
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
  run parse_args --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument '--nope'"* ]]
}

@test "flag values outside their range are rejected" {
  local bad
  for bad in --ro=yes --ephemeral=true --settings=2 --volstate=wram --uid=abc --gid=-1; do
    run parse_args "$bad"
    [ "$status" -eq 1 ] || { echo "accepted $bad"; return 1; }
  done
}

# --- opt-ins ---------------------------------------------------------------

@test "no opt-ins, no flags" {
  setup_cell
  [ "${#RUN_FLAGS[@]}" -eq 0 ] && [ "${#OPTIN_ENV[@]}" -eq 0 ]
}

@test "--ro and --ephemeral become run.sh flags" {
  setup_cell --ro=1 --ephemeral=1
  [ "${RUN_FLAGS[*]}" = "--ro --ephemeral" ]
  [ -z "$VOL_NAME" ]
}

@test "every opt-in sets its flag, env and fixture" {
  setup_cell --optins=aws,glab,tfe,api,az
  [ "${RUN_FLAGS[*]}" = "--aws --glab --tfe --api --az" ]
  [[ " ${OPTIN_ENV[*]} " == *" AWS_PROFILE=default "* ]]
  [[ " ${OPTIN_ENV[*]} " == *" GITLAB_TOKEN=fake-gitlab-token "* ]]
  [[ " ${OPTIN_ENV[*]} " == *" TF_TOKEN_app_terraform_io=fake-tfe-token "* ]]
  [[ " ${OPTIN_ENV[*]} " == *" CLAUDE_DOCKER_API_CA=${FAKE_HOME}/api-ca.crt "* ]]
  [[ " ${OPTIN_ENV[*]} " == *" AZURE_DEVOPS_EXT_PAT=SMOKE-SENTINEL-AZ "* ]]
  grep -q SMOKE-SENTINEL-AWS "${FAKE_HOME}/.aws/config"
  grep -q SMOKE-SENTINEL-GLAB "${FAKE_HOME}/.config/glab-cli/config.yml"
  grep -q SMOKE-SENTINEL-TFE "${FAKE_HOME}/.terraform.d/credentials.tfrc.json"
}

@test "unknown opt-in is rejected" {
  run setup_cell --optins=aws,nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown opt-in: 'nope'"* ]]
}

@test "opt-in list is not glob-expanded" {
  touch "${BATS_TEST_TMPDIR}/aws"
  cd "$BATS_TEST_TMPDIR"
  run setup_cell '--optins=*'
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown opt-in: '*'"* ]]
}

# --- docker shim -----------------------------------------------------------

# Run the generated shim the way run.sh would, with the env run_container sets.
shim() {
  SMOKE_REAL_DOCKER="$SMOKE_REAL_DOCKER" SMOKE_IMAGE="$IMAGE" VOL_NAME="$VOL_NAME" \
    HOST_UID_ARG="$HOST_UID_ARG" HOST_GID_ARG="$HOST_GID_ARG" \
    "${SHIM_DIR}/docker" "$@"
}

@test "shim rewrites ids and volumes and drops -it on the agent run" {
  setup_cell --uid=501 --gid=20 --image=img:1
  run shim run -it -e HOST_UID=1000 -e HOST_GID=1000 \
    -v claude-code-root:/root -v claude-code-home:/root/.claude img:1 claude
  [ "$status" -eq 0 ]
  run cat "${BATS_TEST_TMPDIR}/docker.argv"
  [[ "$output" != *"-it"* ]]
  [[ "$output" == *"HOST_UID=501"*"HOST_GID=20"* ]]
  [[ "$output" == *"smoke-test-$$-root:/root"*"smoke-test-$$-home:/root/.claude"* ]]
  [[ "$output" != *claude-code-root* ]]
}

@test "shim passes a sidecar run through untouched" {
  setup_cell --image=img:1
  shim run -it -e HOST_UID=1000 caddy:2
  [ "$(cat "${BATS_TEST_TMPDIR}/docker.argv")" = "$(printf '%s\n' run -it -e HOST_UID=1000 caddy:2)" ]
}

@test "shim passes non-run commands through" {
  setup_cell
  shim volume rm x
  [ "$(cat "${BATS_TEST_TMPDIR}/docker.argv")" = "$(printf '%s\n' volume rm x)" ]
}

@test "shim fails closed when the agent run no longer matches" {
  setup_cell --image=img:1
  run shim run -e HOST_UID=1000 -e HOST_GID=1000 img:1
  [ "$status" -eq 1 ]
  [[ "$output" == *"volume rewrites=0, want 2/2"* ]]
  [ ! -e "${BATS_TEST_TMPDIR}/docker.argv" ]
}

@test "shim expects no volumes for an ephemeral cell" {
  setup_cell --ephemeral=1 --image=img:1
  run shim run -e HOST_UID=1000 -e HOST_GID=1000 img:1
  [ "$status" -eq 0 ]
}

# --- run_container ---------------------------------------------------------

@test "run_container drives run.sh with the cell's flags, env and expectations" {
  setup_cell --optins=az --ro=1 --image=img:1
  GH_TOKEN=leak run_container 2>/dev/null
  [ "$(cat "${BATS_TEST_TMPDIR}/run.argv")" = "$(printf '%s\n' --ro --az "$WORKSPACE_HOST")" ]
  run cat "${BATS_TEST_TMPDIR}/run.env"
  [[ "$output" == *"HOME=${FAKE_HOME}"* ]]
  [[ "$output" == *"AZURE_DEVOPS_EXT_PAT=SMOKE-SENTINEL-AZ"* ]]
  [[ "$output" == *"CLAUDE_DOCKER_IMAGE=img:1"* ]]
  [[ "$output" == *"CLAUDE_DOCKER_TEST_ENTRY=export EXPECT_UID=1000 EXPECT_GID=1000 EXPECT_OPTINS=az EXPECT_RO=1"* ]]
  [[ "$output" != *GH_TOKEN* ]]
}

@test "run_container returns run.sh's exit status and keeps its stderr" {
  setup_cell
  # env -i strips the caller's env, so the fake run.sh reads files instead.
  printf boom > "${BATS_TEST_TMPDIR}/fake.stderr"
  echo 3 > "${BATS_TEST_TMPDIR}/fake.rc"
  run run_container
  [ "$status" -eq 3 ]
  [[ "$output" == *boom* ]]
  [ "$(cat "$CONTAINER_STDERR")" = boom ]
}

# --- run_cell --------------------------------------------------------------

# Record what each pass would have run with.
record_passes() {
  run_container() {
    local seed=no-seed
    [ -f "$SETTINGS_FIXTURE" ] && seed=$(cat "$SETTINGS_FIXTURE")
    echo "mode=${EXPECT_SETTINGS_MODE} sentinel=${SETTINGS_SENTINEL} seed=${seed}" >> "${BATS_TEST_TMPDIR}/passes"
  }
}

@test "cold cell runs once" {
  setup_cell
  record_passes
  run_cell
  [ "$(wc -l < "${BATS_TEST_TMPDIR}/passes")" -eq 1 ]
}

@test "warm cell re-seeds with V2, then keeps it without a seed" {
  setup_cell --volstate=warm
  record_passes
  run_cell
  run cat "${BATS_TEST_TMPDIR}/passes"
  [ "${lines[0]}" = 'mode=1 sentinel=SMOKE-SENTINEL-SETTINGS seed={"env":{"SMOKE_SENTINEL":"SMOKE-SENTINEL-SETTINGS"}}' ]
  [ "${lines[1]}" = 'mode=1 sentinel=SMOKE-SENTINEL-SETTINGS-V2 seed={"env":{"SMOKE_SENTINEL":"SMOKE-SENTINEL-SETTINGS-V2"}}' ]
  [ "${lines[2]}" = 'mode=keep sentinel=SMOKE-SENTINEL-SETTINGS-V2 seed=no-seed' ]
  [ "${#lines[@]}" -eq 3 ]
}

@test "warm cell without settings runs twice, unseeded" {
  setup_cell --volstate=warm --settings=0
  record_passes
  run_cell
  run cat "${BATS_TEST_TMPDIR}/passes"
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[1]}" = 'mode=0 sentinel=SMOKE-SENTINEL-SETTINGS seed=no-seed' ]
}

# --- assert_host -----------------------------------------------------------

@test "assert_host passes on an owned probe and a clean stderr" {
  setup_cell
  echo probe > "${WORKSPACE_HOST}/smoke-probe.txt"
  : > "$CONTAINER_STDERR"
  run assert_host
  [ "$status" -eq 0 ]
  [[ "$output" == *"no spurious entrypoint WARN"* ]]
}

@test "assert_host fails on a missing probe" {
  setup_cell
  run assert_host
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe file not created"* ]]
}

@test "assert_host fails on an empty probe" {
  setup_cell
  : > "${WORKSPACE_HOST}/smoke-probe.txt"
  run assert_host
  [ "$status" -eq 1 ]
  [[ "$output" == *"probe file is empty"* ]]
}

@test "assert_host fails on the wrong owner" {
  setup_cell
  echo probe > "${WORKSPACE_HOST}/smoke-probe.txt"
  STAT_UID=0
  run assert_host
  [ "$status" -eq 1 ]
  [[ "$output" == *"owned by 0, expected 1000"* ]]
}

@test "assert_host fails loudly when stat fails" {
  setup_cell
  echo probe > "${WORKSPACE_HOST}/smoke-probe.txt"
  STAT_UID=""
  run assert_host
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot stat probe file"* ]]
}

@test "assert_host skips the probe checks for a :ro cell" {
  setup_cell --ro=1
  : > "$CONTAINER_STDERR"
  run assert_host
  [ "$status" -eq 0 ]
  [[ "$output" != *probe* ]]
}

@test "assert_host fails on an entrypoint WARN" {
  setup_cell --ro=1
  echo "entrypoint: WARN chown: x" > "$CONTAINER_STDERR"
  run assert_host
  [ "$status" -eq 1 ]
  [[ "$output" == *"unexpected 'entrypoint: WARN'"* ]]
}

# --- main ------------------------------------------------------------------

@test "main runs a cell end to end against the fake run.sh" {
  fake_docker_bin
  # main builds the workspace itself; point run.sh at the fake once it has.
  write_docker_shim() {
    SMOKE_REAL_DOCKER=docker DOCKER_ENV=()
    RUN_SH="${BATS_TEST_TMPDIR}/fake-run.sh"
    printf '#!/usr/bin/env bash\necho probe > "${!#}/smoke-probe.txt"\n' > "$RUN_SH"
  }
  run main --optins=az
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cell PASS: uid=1000 gid=1000 optins='az'"* ]]
}
