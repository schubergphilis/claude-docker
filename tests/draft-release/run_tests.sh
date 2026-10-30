#!/usr/bin/env bash
# Runs every test_*.sh in this directory and fails if any of them does.
#
#   tests/draft-release/run_tests.sh
#
# Needs bash, jq and awk; gh is not needed, a stub stands in for it. Nothing here reaches the
# network or GitHub, and nothing is written outside a temporary directory.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for tool in jq awk; do
  command -v "${tool}" >/dev/null 2>&1 || { echo "run_tests: ${tool} is required and not on PATH" >&2; exit 2; }
done

failed=0
for test in "${HERE}"/test_*.sh; do
  echo "=== $(basename "${test}")"
  if ! bash "${test}"; then
    failed=$((failed + 1))
  fi
  echo
done

if [[ "${failed}" -gt 0 ]]; then
  echo "run_tests: ${failed} test file(s) failed"
  exit 1
fi
echo "run_tests: all test files passed"
