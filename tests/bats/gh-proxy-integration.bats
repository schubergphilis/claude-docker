#!/usr/bin/env bats
# Unit tests for tests/gh-proxy-integration.sh's helpers; docker, script and
# timeout are stubbed, so no daemon is needed.
#
# Not unit-tested here: phase1_main_session, phase2_concurrent and
# phase3_flags. They are the harness's end-to-end scenarios — real run.sh,
# real sidecar, real containers — and stubbing docker away leaves nothing of
# them to test. They are exercised by running the harness itself (#10).

SUT="${BATS_TEST_DIRNAME}/../gh-proxy-integration.sh"

setup() {
  DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
  # setup_scratch stages under $HOME; keep it off the runner's real one.
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
  # shellcheck source=../gh-proxy-integration.sh
  source "$SUT"
  SCRATCH="$BATS_TEST_TMPDIR"
  NETS=""
  SIDECARS=""
  # Logs every call; `network ls` and `ps -a` print $NETS and $SIDECARS.
  docker() {
    echo "docker $*" >> "$DOCKER_LOG"
    case "$1 $2" in
      "network ls") [ -z "$NETS" ] || printf '%s\n' $NETS ;;
      "ps -a") [ -z "$SIDECARS" ] || printf '%s\n' $SIDECARS ;;
      "info "*) return "${DOCKER_INFO_RC:-1}" ;;
      "image inspect") return "${DOCKER_IMAGE_RC:-0}" ;;
      "run -d") [ -z "${DOCKER_RUN_FAIL:-}" ] || return 1; echo cid-mock ;;
      "ps --filter") echo "${MOCK_RUNNING:-}" ;;
      "logs "*) echo "mock log line" ;;
    esac
  }
  sleep() { :; }
}

@test "sourcing defines main but starts nothing" {
  # Capture the log path first: inside the stub, $2 is the stub's own argument.
  run bash -c 'log=$2; docker() { echo called >> "$log"; }; source "$1"; declare -F main' _ "$SUT" "$DOCKER_LOG"
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
  [ ! -e "$DOCKER_LOG" ]
}

@test "ingest_results_file folds PASS/FAIL/SKIP lines into the counters" {
  printf 'PASS: a\nFAIL: b\nSKIP: c\nRESULT: done\n' > "$SCRATCH/results.txt"
  ingest_results_file "$SCRATCH/results.txt" lbl > "$SCRATCH/out"
  [ "$TOTAL_PASS" -eq 1 ] && [ "$TOTAL_FAIL" -eq 1 ] && [ "$TOTAL_SKIP" -eq 1 ]
  [ "$(cat "$SCRATCH/out")" = "PASS: lbl: a
FAIL: lbl: b
SKIP: lbl: c" ]
}

@test "ingest_results_file records a missing file as one FAIL" {
  ingest_results_file "$SCRATCH/nope" lbl > "$SCRATCH/out"
  [ "$TOTAL_FAIL" -eq 1 ] && [ "$TOTAL_PASS" -eq 0 ]
  grep -q "FAIL: lbl: results file missing" "$SCRATCH/out"
}

@test "new_claude_gh_leftovers ignores the baseline" {
  # Both read by new_claude_gh_leftovers.
  # shellcheck disable=SC2034
  BASELINE_NETS=" claude-gh-live " BASELINE_SIDECARS=" claude-gh-proxy-live "
  NETS="claude-gh-live claude-gh-new"
  SIDECARS="claude-gh-proxy-live claude-gh-proxy-new"
  run new_claude_gh_leftovers
  [ "$output" = "net:claude-gh-new container:claude-gh-proxy-new" ]
  NETS="claude-gh-live" SIDECARS="claude-gh-proxy-live"
  run new_claude_gh_leftovers
  [ -z "$output" ]
}

@test "poll_new_network returns the first network not excluded" {
  NETS="claude-gh-old claude-gh-new"
  run poll_new_network 1 "claude-gh-old"
  [ "$status" -eq 0 ]
  [ "$output" = "claude-gh-new" ]
}

@test "poll_new_network fails when nothing new appears" {
  NETS="claude-gh-old"
  run poll_new_network 3 "claude-gh-old"
  [ "$status" -eq 1 ]
  [ -z "$output" ]
  [ "$(grep -c 'network ls' "$DOCKER_LOG")" -eq 3 ]
}

@test "run_wrapped (util-linux script) returns the wrapped exit status" {
  timeout() { shift 3; "$@"; }
  script() {
    if [ "$1" = --version ]; then echo "script from util-linux 2.39"; return; fi
    [ "$1" = -qec ] || return 99
    echo "$3" > "$SCRATCH/argv-logfile"
    bash -c "$2"
  }
  run run_wrapped "$SCRATCH/log" sh -c 'exit 7'
  [ "$status" -eq 7 ]
  [ "$(cat "$SCRATCH/argv-logfile")" = "$SCRATCH/log" ]
}

@test "run_wrapped (BSD script) returns the wrapped exit status" {
  timeout() { shift 3; "$@"; }
  script() {
    [ "$1" = --version ] && return 1
    [ "$1 $2" = "-q $SCRATCH/log" ] || return 99
    shift 2
    "$@"
  }
  run run_wrapped "$SCRATCH/log" sh -c 'exit 3'
  [ "$status" -eq 3 ]
  run run_wrapped "$SCRATCH/log" true
  [ "$status" -eq 0 ]
}

@test "run_wrapped returns 124 when no rc file was written" {
  timeout() { return 124; }
  script() { return 1; }
  run run_wrapped "$SCRATCH/log" true
  [ "$status" -eq 124 ]
  [ -z "$(find "$SCRATCH" -name 'rc.*')" ]
}

@test "gen_assert_script quotes values containing single quotes" {
  mkdir -p "$SCRATCH/ws"
  gen_assert_script "$SCRATCH/ws/assert.sh" main "tok'en \$x" "1"
  [ -x "$SCRATCH/ws/assert.sh" ]
  bash -n "$SCRATCH/ws/assert.sh"
  # Evaluate just the generated assignments and check they round-trip.
  run bash -c 'eval "$(grep -E "^[A-Z_]+=" "$1")"; printf "%s|%s|%s" "$MODE" "$FAKE_TOKEN" "$RESULTS"' _ "$SCRATCH/ws/assert.sh"
  [ "$output" = "main|tok'en \$x|/workspaces/ws/results.txt" ]
}

@test "make_no_gh_path prepends a gh that always fails" {
  run make_no_gh_path
  [ "$output" = "$SCRATCH/no-gh-bin:$PATH" ]
  run env PATH="$output" gh auth token
  [ "$status" -eq 1 ]
}

@test "hash_file prints the sha256 hex digest" {
  printf 'abc' > "$SCRATCH/f"
  run hash_file "$SCRATCH/f"
  [ "$output" = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" ]
}

@test "kill_tree also kills grandchildren" {
  command sleep 300 &
  local child=$!
  bash -c 'command sleep 300 & echo $! > "$1"; wait' _ "$SCRATCH/grandchild" &
  local parent=$!
  while [ ! -s "$SCRATCH/grandchild" ]; do command sleep 0.1; done
  kill_tree "$parent"
  # The sibling is not in $parent's tree, so it must have survived.
  kill -0 "$child"
  kill "$child"
  wait "$parent" || true
  # An orphaned grandchild can linger as a zombie until init reaps it, and
  # kill -0 succeeds on a zombie, so count state Z as dead.
  local gc _
  gc=$(cat "$SCRATCH/grandchild")
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$gc" 2>/dev/null || return 0
    [ "$(ps -o stat= -p "$gc" 2>/dev/null | cut -c1)" = Z ] && return 0
    command sleep 0.1
  done
  return 1
}

@test "preflight skips with exit 0 when docker is unavailable" {
  run preflight
  [ "$status" -eq 0 ]
  [[ "$output" == SKIP:* ]]
}

@test "preflight fails when GH_PROXY_IT_REQUIRE_DOCKER=1 and docker is unavailable" {
  GH_PROXY_IT_REQUIRE_DOCKER=1 run preflight
  [ "$status" -eq 1 ]
  [[ "$output" == FATAL:* ]]
}

@test "main stops before the phases when mktemp fails" {
  preflight() { :; }
  mktemp() { return 1; }
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not create a scratch dir"* ]]
  [[ "$output" != *"Pre-flight"* ]]
  [[ "$output" != *"Phase 1"* ]]
}

@test "main stops before the phases when the mock fails to start" {
  preflight() { :; }
  setup_scratch() { SCRATCH="$BATS_TEST_TMPDIR/s"; mkdir -p "$SCRATCH"; }
  start_mock() { echo "mock failed"; return 1; }
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"mock failed"* ]]
  [[ "$output" != *"Phase 1"* ]]
}

# --- preflight ---------------------------------------------------------------

@test "preflight fails without script" {
  mkdir -p "$BATS_TEST_TMPDIR/empty"
  DOCKER_INFO_RC=0 PATH="$BATS_TEST_TMPDIR/empty" run preflight
  [ "$status" -eq 1 ]
  [[ "$output" == "FATAL: 'script' not found"* ]]
}

@test "preflight fails when the image is missing" {
  script() { :; }
  DOCKER_INFO_RC=0 DOCKER_IMAGE_RC=1 CLAUDE_DOCKER_IMAGE=img:x run preflight
  [ "$status" -eq 1 ]
  [[ "$output" == "FATAL: image 'img:x' not found"* ]]
}

@test "preflight fails when run.sh is missing" {
  # A copy of the harness with no run.sh beside its parent dir.
  mkdir -p "$BATS_TEST_TMPDIR/repo/tests"
  cp "$SUT" "$BATS_TEST_TMPDIR/repo/tests/"
  run bash -c 'docker() { :; }; script() { :; }; source "$1"; preflight' _ \
    "$BATS_TEST_TMPDIR/repo/tests/gh-proxy-integration.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == "FATAL: run.sh not found at $BATS_TEST_TMPDIR/repo/run.sh" ]]
}

@test "preflight sets TARGET_IMAGE and RUN_SH when everything is present" {
  script() { :; }
  DOCKER_INFO_RC=0
  preflight
  [ "$TARGET_IMAGE" = claude-code:local ]
  [ -f "$RUN_SH" ]
}

# --- cleanup / summary -------------------------------------------------------

# Runs cleanup from a real EXIT trap in a child bash, exiting with $1.
exit_through_cleanup() {
  run bash -c 'log=$3; docker() { echo "docker $*" >> "$log"; }; source "$1"
    SCRATCH=$2 MOCK_CID=cid-mock; trap cleanup EXIT; exit "$4"' _ \
    "$SUT" "$SCRATCH" "$DOCKER_LOG" "$1"
}

@test "cleanup removes the scratch dir after a clean run" {
  SCRATCH="$BATS_TEST_TMPDIR/s"; mkdir -p "$SCRATCH"
  exit_through_cleanup 0
  [ "$status" -eq 0 ]
  [ ! -e "$SCRATCH" ]
  grep -q 'docker rm -f cid-mock' "$DOCKER_LOG"
}

@test "cleanup keeps the scratch dir when a check failed" {
  SCRATCH="$BATS_TEST_TMPDIR/s"; mkdir -p "$SCRATCH"
  TOTAL_FAIL=1
  run eval 'true; cleanup'
  [ -d "$SCRATCH" ]
  [[ "$output" == *"keeping scratch dir for debugging: $SCRATCH"* ]]
}

@test "cleanup keeps the scratch dir when the run aborted" {
  SCRATCH="$BATS_TEST_TMPDIR/s"; mkdir -p "$SCRATCH"
  exit_through_cleanup 1
  [ "$status" -eq 1 ]
  [ -d "$SCRATCH" ]
  [[ "$output" == *"keeping scratch dir"* ]]
}

@test "cleanup with no scratch dir removes nothing" {
  SCRATCH=""
  rm() { echo "rm $*" >> "$BATS_TEST_TMPDIR/rm.log"; }
  run cleanup
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/rm.log" ]
}

@test "cleanup stops background sessions and runs once" {
  command sleep 300 &
  BG_PIDS=("$!")
  SCRATCH=""
  cleanup
  run kill -0 "${BG_PIDS[0]}"
  [ "$status" -ne 0 ]
  : > "$DOCKER_LOG"
  cleanup
  [ ! -s "$DOCKER_LOG" ]
}

@test "summary returns 0 when nothing failed" {
  TOTAL_PASS=3
  run summary
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS=3 FAIL=0 SKIP=0"*"RESULT: PASS" ]]
}

@test "summary returns 1 when a check failed" {
  TOTAL_FAIL=1
  run summary
  [ "$status" -eq 1 ]
  [[ "$output" == *"RESULT: FAIL" ]]
}

# --- start_mock --------------------------------------------------------------

@test "start_mock fails when docker run fails" {
  DOCKER_RUN_FAIL=1 run start_mock
  [ "$status" -eq 1 ]
  [[ "$output" == *"FATAL: could not start the mock GitHub upstream"* ]]
}

@test "start_mock fails when the mock exits immediately" {
  run start_mock
  [ "$status" -eq 1 ]
  [[ "$output" == *"exited immediately"*"mock log line"* ]]
}

@test "start_mock succeeds once the mock is running" {
  MOCK_RUNNING=cid-mock
  start_mock > /dev/null
  [ "$MOCK_CID" = cid-mock ]
  grep -q 'auto_https off' "$SCRATCH/mock-Caddyfile"
}

# --- small helpers -----------------------------------------------------------

@test "record_rc_zero records a pass for 0 and a fail otherwise" {
  record_rc_zero 0 lbl > /dev/null
  record_rc_zero 2 lbl log.txt > "$SCRATCH/out"
  [ "$TOTAL_PASS" -eq 1 ] && [ "$TOTAL_FAIL" -eq 1 ]
  [ "$(cat "$SCRATCH/out")" = "FAIL: lbl exited 2 (see log.txt)" ]
}

@test "run_wrapped_wait records the pid and the exit status" {
  run_wrapped() { return 5; }
  run_wrapped_wait log cmd
  [ "$RC" -eq 5 ]
  [ "${#BG_PIDS[@]}" -eq 1 ]
}

@test "start_concurrent_session backgrounds run.sh and finds its network" {
  run_wrapped() { echo "$*" > "$SCRATCH/wrapped"; }
  poll_new_network() { echo claude-gh-new; }
  RUN_SH=/x/run.sh TARGET_IMAGE=img
  start_concurrent_session ws-a ghp_a
  wait "$PID"
  [ "$NET" = claude-gh-new ]
  [ "${BG_PIDS[0]}" = "$PID" ]
  [[ "$(cat "$SCRATCH/wrapped")" == "$SCRATCH/run-ws-a.log env GH_TOKEN=ghp_a "*"bash /x/run.sh --gh $SCRATCH/ws-a" ]]
}

@test "capture_baseline records live claude-gh resources" {
  NETS="claude-gh-live" SIDECARS="claude-gh-proxy-live"
  capture_baseline > /dev/null
  [[ "$BASELINE_NETS" == *claude-gh-live* ]]
  [[ "$BASELINE_SIDECARS" == *claude-gh-proxy-live* ]]
}
