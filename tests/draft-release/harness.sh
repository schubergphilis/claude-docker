#!/usr/bin/env bash
# Runs the action's step script once, against the stub gh.
#
# The script is lifted out of action.yml rather than copied into the tests, so the tests cannot
# drift from the action: a change to the `run:` block is a change to what runs here.
#
# A case sets FIXTURES, and any of the action's inputs it cares about, then calls this. Output
# is the script's own, followed by the outputs it wrote, the writes it attempted, and the notes
# it rendered -- which is what the assertions read.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ACTION="${ACTION:-${HERE}/../../.github/actions/draft-release/action.yml}"

: "${FIXTURES:?FIXTURES must point at a fixture directory}"
export FIXTURES
export PATH="${HERE}/stub:${PATH}"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# The step is written as one `run: |` block, indented eight spaces under it.
awk '/^      run: \|$/ {found=1; next} found {print substr($0, 9)}' "${ACTION}" > "${work}/step.sh"
[[ -s "${work}/step.sh" ]] || { echo "harness: no run: block found in ${ACTION}" >&2; exit 1; }

: > "${FIXTURES}/calls.log"
rm -f "${FIXTURES}/field_body"

# The action's inputs, as the runner would pass them. A case overrides what it is about.
export GH_TOKEN="${GH_TOKEN:-stub-token}"
export REPOSITORY="${REPOSITORY:-OWNER/REPO}"
export HEAD_SHA="${HEAD_SHA:-head0000}"
export TARGET="${TARGET:-main}"
export PREVIOUS_TAG="${PREVIOUS_TAG:-}"
export VERSION_PREFIX="${VERSION_PREFIX:-v}"
export FIRST_VERSION="${FIRST_VERSION:-v0.1.0}"
export MINOR_TYPES="${MINOR_TYPES:-feat}"
export PRE_MAJOR="${PRE_MAJOR:-true}"
export CATEGORIES="${CATEGORIES:-$(printf '%s\n' \
  'Features: feat' \
  'Fixes: fix' \
  'Performance: perf' \
  'Documentation: docs' \
  'Maintenance: build chore ci refactor style test revert')}"
export OTHER_CATEGORY="${OTHER_CATEGORY:-Other changes}"
export PRERELEASE="${PRERELEASE:-false}"
export DRY_RUN="${DRY_RUN:-false}"
export GITHUB_OUTPUT="${work}/github_output"
export GITHUB_STEP_SUMMARY="${work}/step_summary"
: > "${GITHUB_OUTPUT}"
: > "${GITHUB_STEP_SUMMARY}"

rc=0
bash "${work}/step.sh" || rc=$?

echo "=== outputs ==="
cat "${GITHUB_OUTPUT}"
echo "=== writes ==="
grep -E 'WRITE|FORBIDDEN' "${FIXTURES}/calls.log" || echo "(none)"
echo "=== notes ==="
cat "${FIXTURES}/field_body" 2>/dev/null || echo "(no notes written)"

exit "${rc}"
