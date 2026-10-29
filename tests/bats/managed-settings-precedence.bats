#!/usr/bin/env bats
# Unit tests for tests/integration/managed-settings-precedence.sh and its
# in-container half, precedence-in-container.sh. docker, claude, npm and sleep
# are stubbed, so no daemon or image is needed.
#
# Not unit-tested here: start_servers, set_run_env and run_cases. They start
# node servers, edit /etc/hosts and drive the real claude; the harness itself
# exercises them in ci.yml's docker-build job.
# Globals set here are read by the sourced functions (SC2034).
# shellcheck disable=SC2034

HOST_SUT="${BATS_TEST_DIRNAME}/../integration/managed-settings-precedence.sh"
IN_SUT="${BATS_TEST_DIRNAME}/../integration/precedence-in-container.sh"

setup() {
  DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  # Both define main; the host script's, sourced last, is the one tested.
  # shellcheck source=../integration/precedence-in-container.sh
  source "$IN_SUT"
  # shellcheck source=../integration/managed-settings-precedence.sh
  source "$HOST_SUT"
  # Logs every call; fails the run whose mode/suite is in $DOCKER_FAIL.
  DOCKER_FAIL=""
  docker() {
    echo "docker $*" >> "$DOCKER_LOG"
    local args=("$@")
    [[ " $DOCKER_FAIL " != *" ${args[-2]}/${args[-1]} "* ]]
  }
  # Real waits, but short: check polls the logs while claude runs.
  sleep() { command sleep 0.05; }

  W="$BATS_TEST_TMPDIR/w"
  mkdir -p "$W"
  fails=0
  run_env=(ANTHROPIC_BASE_URL=http://127.0.0.1:9001)
  # exec bypasses shell functions, so claude is a PATH stub. It logs its
  # cwd and args, and sends one model request to the port in $W/target
  # (none if the file is empty), as the logging server would record it.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/claude" <<SH
#!/bin/sh
echo "\$PWD \$*" >> "$W/claude.calls"
port=\$(cat "$W/target")
[ -z "\$port" ] || echo "POST /v1/messages" >> "$W/\$port.log"
echo "stub claude output"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/claude"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

# Runs check and reports the fail count, which `run`'s subshell would lose.
check_counted() {
  check "$@"
  echo "fails=$fails"
}

# --- sourcing --------------------------------------------------------------

@test "sourcing the host script defines main but starts nothing" {
  run bash -c 'log=$2; docker() { echo called >> "$log"; }; source "$1"; declare -F main' _ "$HOST_SUT" "$DOCKER_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ ! -e "$DOCKER_LOG" ]
}

@test "sourcing the in-container script defines main but starts nothing" {
  run bash -c 'node() { echo started; }; source "$1"; declare -F main' _ "$IN_SUT"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# --- check -----------------------------------------------------------------

@test "check: managed run passes when only the managed endpoint gets the request" {
  mode=managed; echo 9001 > "$W/target"
  run check_counted settings settings.json '"A":"1"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: settings: managed settings win (:9001 1, :9002 0)"* ]]
  [[ "$output" == *"fails=0" ]]
}

@test "check: managed run fails when the override gets the request" {
  mode=managed; echo 9002 > "$W/target"
  run check_counted settings settings.json '"A":"1"'
  [[ "$output" == *"FAIL: settings: :9001 0, :9002 1 (stub claude output )"* ]]
  [[ "$output" == *"fails=1" ]]
}

@test "check: managed run fails when no request arrives at all" {
  mode=managed; : > "$W/target"
  run check_counted settings settings.json '"A":"1"'
  [[ "$output" == *"FAIL: settings: :9001 0, :9002 0"* ]]
  [[ "$output" == *"fails=1" ]]
}

@test "check: control run passes when the override wins" {
  mode=control; echo 9002 > "$W/target"
  run check_counted vertex settings.json '"A":"1"'
  [[ "$output" == *"PASS: control vertex: the override wins without managed settings (:9002 1)"* ]]
  [[ "$output" == *"fails=0" ]]
}

@test "check: control run fails when the override does not win" {
  mode=control; echo 9001 > "$W/target"
  run check_counted vertex settings.json '"A":"1"'
  [[ "$output" == *"FAIL: control vertex: the override did not win (:9001 1, :9002 0), so the cases prove nothing"* ]]
  [[ "$output" == *"fails=1" ]]
}

@test "check: a settings file case writes the env into the project's .claude/" {
  mode=managed; echo 9001 > "$W/target"
  run check local settings.local.json '"K":"v"'
  [ "$(cat "$W/local/proj/.claude/settings.local.json")" = '{"env":{"K":"v"}}' ]
  [ "$(cat "$W/claude.calls")" = "$W/local/proj -p hi" ]
}

@test "check: the --settings case passes the env as a flag file" {
  mode=managed; echo 9001 > "$W/target"
  run check flag --settings '"K":"v"'
  [ "$(cat "$W/flag/flag.json")" = '{"env":{"K":"v"}}' ]
  [ ! -e "$W/flag/proj/.claude/--settings" ]
  [ "$(cat "$W/claude.calls")" = "$W/flag/proj --settings $W/flag/flag.json -p hi" ]
}

@test "check: each case starts from empty server logs" {
  mode=managed
  echo "POST /v1/messages" > "$W/9002.log"
  echo 9001 > "$W/target"
  run check_counted settings settings.json '"A":"1"'
  [[ "$output" == *"PASS: settings"* ]]
}

# --- check_switches --------------------------------------------------------

# A fake global npm root whose bundle names the given switches, and managed
# settings with the given env.
fake_bundle() {
  local env="$1"; shift
  local pkg="$BATS_TEST_TMPDIR/npm/@anthropic-ai/claude-code"
  mkdir -p "$pkg"
  printf 'process.env.%s;\n' "$@" > "$pkg/cli.js"
  npm() { echo "$BATS_TEST_TMPDIR/npm"; }
  MANAGED_SETTINGS="$BATS_TEST_TMPDIR/managed.json"
  printf '{"env":{%s}}' "$env" > "$MANAGED_SETTINGS"
}

check_switches_counted() {
  check_switches
  echo "fails=$fails"
}

@test "check_switches: every backend switch pinned off passes" {
  fake_bundle '"CLAUDE_CODE_USE_BEDROCK":"0","CLAUDE_CODE_USE_VERTEX":"0"' \
    CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_VERTEX CLAUDE_CODE_USE_BEDROCK
  run check_switches_counted
  [ "$output" = "PASS: switch CLAUDE_CODE_USE_BEDROCK is pinned off
PASS: switch CLAUDE_CODE_USE_VERTEX is pinned off
fails=0" ]
}

@test "check_switches: a backend switch the settings don't pin fails" {
  fake_bundle '"CLAUDE_CODE_USE_BEDROCK":"0"' CLAUDE_CODE_USE_BEDROCK CLAUDE_CODE_USE_NEWCLOUD
  run check_switches_counted
  [[ "$output" == *"FAIL: switch CLAUDE_CODE_USE_NEWCLOUD is not pinned off"* ]]
  [[ "$output" == *"fails=1" ]]
}

@test "check_switches: a switch pinned to anything but \"0\" fails" {
  fake_bundle '"CLAUDE_CODE_USE_BEDROCK":"1"' CLAUDE_CODE_USE_BEDROCK
  run check_switches_counted
  [[ "$output" == *"FAIL: switch CLAUDE_CODE_USE_BEDROCK is not pinned off"* ]]
  [[ "$output" == *"fails=1" ]]
}

@test "check_switches: switches that pick no backend are skipped" {
  fake_bundle '' CLAUDE_CODE_USE_CCR_V2 CLAUDE_CODE_USE_POWERSHELL_TOOL
  run check_switches_counted
  [ "$output" = "fails=0" ]
}

@test "check_switches: a bundle with no switches fails instead of passing vacuously" {
  fake_bundle '' SOMETHING_ELSE
  run check_switches_counted
  [[ "$output" == *"FAIL: no CLAUDE_CODE_USE_* switch found under $BATS_TEST_TMPDIR/npm/@anthropic-ai/claude-code"* ]]
  [[ "$output" == *"fails=1" ]]
}

# --- run_mode and main ------------------------------------------------------

@test "run_mode: managed mounts the suite's managed settings read-only" {
  REPO=/repo TMP=/tmp/x IMAGE=img:tag
  run run_mode managed proxy
  [ "$status" -eq 0 ]
  [ "$(cat "$DOCKER_LOG")" = "docker run --rm --network none --user 0 --entrypoint bash -v /repo/tests/integration/precedence-in-container.sh:/precedence.sh:ro -v /tmp/x/managed-proxy.json:/etc/claude-code/managed-settings.json:ro img:tag /precedence.sh managed proxy" ]
}

@test "run_mode: control mounts no managed settings" {
  REPO=/repo TMP=/tmp/x IMAGE=img:tag
  run run_mode control endpoint
  [ "$status" -eq 0 ]
  [[ "$(cat "$DOCKER_LOG")" != *managed-settings.json* ]]
  [[ "$(cat "$DOCKER_LOG")" == *"img:tag /precedence.sh control endpoint" ]]
}

@test "run_mode: a failing docker run fails the mode" {
  REPO=/repo TMP=/tmp/x IMAGE=img:tag DOCKER_FAIL="managed/endpoint"
  run run_mode managed endpoint
  [ "$status" -ne 0 ]
}

@test "main: runs both modes of both suites and passes" {
  run main
  [ "$status" -eq 0 ]
  [ "${lines[-1]}" = "RESULT: PASS" ]
  [ "$(grep -o '/precedence.sh .*' "$DOCKER_LOG")" = "/precedence.sh control endpoint
/precedence.sh managed endpoint
/precedence.sh control proxy
/precedence.sh managed proxy" ]
}

@test "main: one failing run fails the result but the rest still run" {
  DOCKER_FAIL="control/endpoint"
  run main
  [ "$status" -eq 1 ]
  [ "${lines[-1]}" = "RESULT: FAIL" ]
  [ "$(grep -c '/precedence.sh' "$DOCKER_LOG")" -eq 4 ]
}

@test "main: writes both suites' managed settings from run.sh" {
  # Keep the temp dir: main's EXIT trap would remove it before we look.
  rm() { :; }
  mktemp() { mkdir -p "$BATS_TEST_TMPDIR/tmp"; echo "$BATS_TEST_TMPDIR/tmp"; }
  run main
  [ "$status" -eq 0 ]
  [ "$(jq -r .env.ANTHROPIC_BASE_URL "$BATS_TEST_TMPDIR/tmp/managed-endpoint.json")" = http://127.0.0.1:9001 ]
  [ "$(jq -r .env.HTTPS_PROXY "$BATS_TEST_TMPDIR/tmp/managed-endpoint.json")" = http://127.0.0.1:9003 ]
  [ "$(jq -r .env.ANTHROPIC_BASE_URL "$BATS_TEST_TMPDIR/tmp/managed-proxy.json")" = http://claude-docker-api-proxy:9002 ]
  [ "$(jq -r .env.HTTPS_PROXY "$BATS_TEST_TMPDIR/tmp/managed-proxy.json")" = http://127.0.0.1:9001 ]
}
