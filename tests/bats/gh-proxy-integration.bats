#!/usr/bin/env bats
# Unit tests for tests/gh-proxy-integration.sh's pure helpers; docker, script
# and timeout are stubbed, so no daemon is needed.

SUT="${BATS_TEST_DIRNAME}/../gh-proxy-integration.sh"

setup() {
  DOCKER_LOG="$BATS_TEST_TMPDIR/docker.log"
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
      "info "*) return 1 ;;
    esac
  }
  sleep() { :; }
}

@test "sourcing defines main but starts nothing" {
  run bash -c 'docker() { echo called >> "$2"; }; source "$1"; declare -F main' _ "$SUT" "$DOCKER_LOG"
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
  kill "$child"
  wait "$parent" || true
  ! kill -0 "$(cat "$SCRATCH/grandchild")" 2>/dev/null
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
