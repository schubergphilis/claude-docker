#!/usr/bin/env bash
# Shared by the test_*.sh files. Sourced, not run.
#
# A test file makes a fixture directory with fresh_fixtures, fills it, calls run with any
# inputs it wants to override, and reads the result through the helpers below. Every helper
# prints exactly one line, so a check compares one string to another and nothing else.

HERE="${HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

pass=0
fail=0
SCRATCH="$(mktemp -d)"
trap 'rm -rf "${SCRATCH}"' EXIT

section() { printf -- '--- %s %s\n' "$1" "$(printf '%*s' $((72 - ${#1})) '' | tr ' ' '-')"; }

# check <name> <expectation> <actual> <expected>
check() {
  if [[ "$3" == "$4" ]]; then
    printf 'PASS  %-32s %s\n' "$1" "$2"
    pass=$((pass + 1))
  else
    printf 'FAIL  %-32s %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$4" "$3"
    fail=$((fail + 1))
  fi
}

# A fresh, empty fixture directory in F.
fresh_fixtures() {
  F="${SCRATCH}/fixtures"
  rm -rf "${F}"
  mkdir -p "${F}"
}

# run [VAR=value ...]: the harness against F, with these inputs on top of the defaults.
run() {
  env FIXTURES="${F}" "$@" bash "${HERE}/harness.sh" > "${F}/out.txt" 2>&1
  echo $? > "${F}/rc"
}

rc()            { cat "${F}/rc"; }
field()         { grep "^$1=" "${F}/out.txt" | tail -1 | cut -d= -f2-; }
# grep -c prints its count even when it is 0 (and exits 1), so the fallback is only for a
# missing file, never a second line.
writes()        { { grep -cE '^WRITE' "${F}/calls.log" 2>/dev/null || true; } | grep . || echo 0; }
notes()         { cat "${F}/field_body" 2>/dev/null; }
count_log()     { grep -c -- "$1" "${F}/out.txt" || true; }
count_notes()   { notes | grep -c -- "$1" || true; }
count_warning() { grep -c -- "::warning title=$1" "${F}/out.txt" || true; }
count_error()   { grep -c -- "::error title=$1" "${F}/out.txt" || true; }

finish() {
  echo
  echo "${pass} passed, ${fail} failed"
  [[ "${fail}" -eq 0 ]]
}
