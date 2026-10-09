#!/usr/bin/env bats
# Unit tests for scripts/audit-npm-pins.sh; python3 and npm are stubbed (no network).

setup() {
  # shellcheck source=../../scripts/audit-npm-pins.sh
  source "${BATS_TEST_DIRNAME}/../../scripts/audit-npm-pins.sh"
  export TMPDIR="$BATS_TEST_TMPDIR/tmp"
  mkdir -p "$TMPDIR"
  TOOLS="" AUDIT_RC=0 LIST_RC=0 FAIL_NPM=""
  NPM_LOG="$BATS_TEST_TMPDIR/npm.log"
  : > "$NPM_LOG"
  python3() {
    case "$2" in
      --audit) return "$AUDIT_RC" ;;
      --list-tools) printf '%s' "$TOOLS"; return "$LIST_RC" ;;
    esac
  }
  # Logs each call; fails the subcommand named in $FAIL_NPM.
  npm() {
    echo "$*" >> "$NPM_LOG"
    [ "$1" != "$FAIL_NPM" ]
  }
}

# row NAME VERSION KIND PKG
row() { printf '%s\tprobe\tre\t%s\t%s\t%s\n' "$@"; }

@test "npm row is installed and signature-checked, scratch dir removed" {
  TOOLS=$(row tool 1.2.3 npm @scope/tool)
  run main
  [ "$status" -eq 0 ]
  grep -qx 'install --ignore-scripts --no-audit --no-fund --silent @scope/tool@1.2.3' "$NPM_LOG"
  grep -qx 'audit signatures' "$NPM_LOG"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "malformed row (empty last column) exits 1" {
  TOOLS=$(printf 'tool\tprobe\tre\t1.2.3\tnpm\t\n')
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::malformed --list-tools row for tool"* ]]
  [ ! -s "$NPM_LOG" ]
}

@test "non-npm row is skipped" {
  TOOLS=$(row gh 2.0.0 github cli/cli)
  run main
  [ "$status" -eq 0 ]
  [ ! -s "$NPM_LOG" ]
}

@test "npm row with no version exits 1" {
  # Via main an empty version collapses into a malformed row, so call
  # audit_tool directly to reach the version check.
  run audit_tool tool "" npm pkg
  [ "$status" -eq 1 ]
  [[ "$output" == *"::error::no pinned version for tool"* ]]
  [ ! -s "$NPM_LOG" ]
}

@test "failing --audit aborts before any signature check" {
  AUDIT_RC=1 TOOLS=$(row tool 1.2.3 npm pkg)
  run main
  [ "$status" -ne 0 ]
  [ ! -s "$NPM_LOG" ]
}

@test "failing --list-tools aborts" {
  LIST_RC=3 TOOLS=$(row tool 1.2.3 npm pkg)
  run main
  [ "$status" -ne 0 ]
  [ ! -s "$NPM_LOG" ]
}

@test "empty --list-tools output fails closed" {
  TOOLS=""
  run main
  [ "$status" -eq 1 ]
}

@test "failing npm install exits non-zero, cleans up, stops the loop" {
  FAIL_NPM=install
  TOOLS="$(row a 1.0.0 npm a)
$(row b 1.0.0 npm b)"
  run main
  [ "$status" -ne 0 ]
  [[ "$(<"$NPM_LOG")" != *'audit signatures'* ]]
  [[ "$(<"$NPM_LOG")" != *'b@1.0.0'* ]]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "failing npm audit signatures exits non-zero and cleans up" {
  FAIL_NPM=audit TOOLS=$(row tool 1.2.3 npm pkg)
  run main
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "a signal mid-install still removes the scratch dir" {
  TOOLS=$(row tool 1.2.3 npm @scope/tool)
  local pidf="$BATS_TEST_TMPDIR/main.pid"
  # Kill main's shell and this subshell, as a cancelled CI job would.
  npm() {
    [ "$1" = install ] || return 0
    kill -TERM "$(cat "$pidf")" "$BASHPID"
  }
  ( echo "$BASHPID" > "$pidf"; main ) &
  wait $! || true
  [ -z "$(ls -A "$TMPDIR")" ]
}
