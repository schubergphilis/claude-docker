#!/usr/bin/env bash
# Runs the validate-pr-title action's step script against a list of titles.
#
#   tests/validate-pr-title/run_tests.sh
#
# The script is lifted out of action.yml rather than copied here, so the tests cannot drift
# from the action. Needs bash and awk; nothing reaches the network or GitHub.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${HERE}/../../.github/actions/validate-pr-title/action.yml"
TYPES_DEFAULT='build chore ci docs feat fix perf refactor revert style test'

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The step is written as one `run: |` block, indented eight spaces under it.
awk '/^      run: \|$/ {found=1; next} found {print substr($0, 9)}' "${ACTION}" > "${work}/step.sh"
[[ -s "${work}/step.sh" ]] || { echo "run_tests: no run: block found in ${ACTION}" >&2; exit 1; }

passed=0
failed=0

# expect <pass|fail> <title> [types]
expect() {
  local want="$1" title="$2" types="${3-${TYPES_DEFAULT}}" rc=0
  (cd "${work}" && TITLE="${title}" TYPES="${types}" bash step.sh) > "${work}/out" 2>&1 || rc=$?
  local got='pass'
  [[ "${rc}" -ne 0 ]] && got='fail'
  if [[ "${got}" == "${want}" ]]; then
    passed=$((passed + 1))
  else
    failed=$((failed + 1))
    printf 'FAIL: expected %s, got %s: %q\n' "${want}" "${got}" "${title}"
    sed 's/^/    /' "${work}/out"
  fi
}

# Conventional Commit titles pass.
expect pass 'feat: add a flag'
expect pass 'fix(run): read host files without following symlinks'
expect pass 'build(deps): bump astral-sh/setup-uv'
expect pass 'feat!: drop the old flag'
expect pass 'refactor(run)!: rename the session variable'
expect pass 'ci: correct the checkout version comment in PR validation'
expect pass 'revert: feat: add a flag'
for type in ${TYPES_DEFAULT}; do
  expect pass "${type}: something"
done

# Anything else fails.
expect fail 'Fix typo'
expect fail 'Merge pull request #1 from someone/branch'
expect fail 'feature: add a flag'
expect fail 'Feat: add a flag'
expect fail 'feat:add a flag'
expect fail 'feat:  add a flag'
expect fail 'feat: '
expect fail 'feat():  add a flag'
expect fail 'feat() : add a flag'
expect fail 'feat!!: add a flag'
expect fail 'feat(a(b)): add a flag'
expect fail ' feat: add a flag'
expect fail ''
expect fail $'Fix typo\nfeat: add a flag'

# The types input narrows the set, and accepts commas.
expect pass 'docs: x' 'feat,fix docs'
expect fail 'ci: x' 'feat fix docs'
expect fail 'feat: x' ''

# A title is data: nothing in it runs, and it can't start a workflow command.
expect fail 'Fix $(touch pwned) `touch pwned2` ${HOME}'
expect pass 'feat: $(touch pwned) `touch pwned2`'
if [[ -e "${work}/pwned" || -e "${work}/pwned2" ]]; then
  failed=$((failed + 1))
  echo 'FAIL: a command in the title ran'
else
  passed=$((passed + 1))
fi
TITLE=$'Fix typo\n::warning::injected 100%' TYPES="${TYPES_DEFAULT}" bash "${work}/step.sh" > "${work}/out" 2>&1
if grep -q '^::warning::' "${work}/out" || ! grep -q 'Fix typo%0A::warning::injected 100%25' "${work}/out"; then
  failed=$((failed + 1))
  echo 'FAIL: the title was not escaped in the annotation'
  sed 's/^/    /' "${work}/out"
else
  passed=$((passed + 1))
fi

echo "run_tests: ${passed} passed, ${failed} failed"
[[ "${failed}" -eq 0 ]]
