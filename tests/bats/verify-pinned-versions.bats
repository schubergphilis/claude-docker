#!/usr/bin/env bats
# Unit tests for scripts/verify-pinned-versions.sh; docker and the registry are stubbed.

setup() {
  # shellcheck source=../../scripts/verify-pinned-versions.sh
  source "${BATS_TEST_DIRNAME}/../../scripts/verify-pinned-versions.sh"
  # Stub probe output, keyed by the probe's first word.
  docker() {
    case "$4" in
      good) echo "good 1.2.3" ;;
      bad) echo "bad 9.9.9" ;;
      junk) echo "no version here" ;;
      *) return 1 ;;
    esac
  }
  TOOLS=""
  list_tools() { printf '%s' "$TOOLS"; }
}

row() { printf '%s\t%s\t%s\t%s\tgithub\tx\n' "$1" "$2" "$3" "$4"; }

@test "matching version passes" {
  run check_tool good "good --version" 'good ([0-9.]+)' 1.2.3
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS  good"* ]]
}

@test "wrong version fails with an ::error:: line" {
  run check_tool bad "bad --version" 'bad ([0-9.]+)' 1.2.3
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  bad"* ]]
  [[ "$output" == *"::error::bad: pinned 1.2.3, image reported 'bad 9.9.9'"* ]]
}

@test "unmatched output fails" {
  run check_tool junk "junk" 'v([0-9.]+)' 1.2.3
  [ "$status" -eq 1 ]
}

@test "regex without a capture group fails instead of aborting" {
  run bash -c 'set -u; source "$1"; docker() { echo "good 1.2.3"; }; check_tool good good "good [0-9.]+" 1.2.3' _ \
    "${BATS_TEST_DIRNAME}/../../scripts/verify-pinned-versions.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL  good"* ]]
}

@test "failed probe is reported and later tools are still checked" {
  TOOLS="$(row gone gone 'x' 1)
$(row good 'good --version' 'good ([0-9.]+)' 1.2.3)"
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"reported=<probe failed>"* ]]
  [[ "$output" == *"PASS  good"* ]]
}

@test "all tools passing exits 0" {
  TOOLS="$(row good 'good --version' 'good ([0-9.]+)' 1.2.3)"
  run main
  [ "$status" -eq 0 ]
}

@test "empty tool list fails closed" {
  TOOLS=""
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"listed no tools"* ]]
}

@test "failing --list-tools aborts" {
  list_tools() { return 3; }
  run main
  [ "$status" -ne 0 ]
}
