#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# Runtime version check, run from the repo root by ci.yml's `docker-build` job:
# every pinned CLI in the claude-docker:ci image reports its pinned version.
# The tool set, each tool's version probe, and the rule for reading a version
# out of that probe all come from update_pins.py's registry, so a newly pinned
# tool is covered without editing this file.

IMAGE=claude-docker:ci

# Registry rows: name, probe, version_re, pinned, kind, ref (tab-separated).
list_tools() {
  python3 update_pins.py --list-tools
}

# Probe one tool in the image and print its PASS/FAIL line; non-zero on FAIL.
check_tool() {
  local name=$1 probe=$2 version_re=$3 pinned=$4 actual="" status
  local -a argv
  read -ra argv <<< "$probe"
  # One conditional chain, not three statements: an unrunnable tool,
  # an unreadable version and a wrong version must each land in the
  # `else` instead of tripping `set -e` and skipping the tools after
  # it. $version_re is deliberately unquoted — quoting the right-hand
  # side of =~ makes bash match it as a literal string, not a regex.
  # </dev/null keeps docker away from the caller's here-string.
  if actual=$(docker run --rm "$IMAGE" "${argv[@]}" </dev/null) \
     && [[ "$actual" =~ $version_re ]] \
     && [ "${BASH_REMATCH[1]-}" = "$pinned" ]; then
    status=PASS
  else
    status=FAIL
  fi
  echo "  ${status}  ${name}  pinned=${pinned}  reported=${actual:-<probe failed>}"
  [ "$status" = PASS ] && return 0
  echo "::error::${name}: pinned ${pinned}, image reported '${actual:-<probe failed>}'"
  return 1
}

main() {
  set -euo pipefail
  local tools fail=0 count=0 name probe version_re pinned
  # Capture before looping. --list-tools is fail-closed, and `$(...)`
  # propagates its non-zero exit under `set -e` where a
  # `done < <(cmd)` process substitution would not.
  tools=$(list_tools)
  while IFS=$'\t' read -r name probe version_re pinned _ _; do
    [ -n "$name" ] || continue
    count=$((count + 1))
    check_tool "$name" "$probe" "$version_re" "$pinned" || fail=1
  done <<< "$tools"
  if [ "$count" -eq 0 ]; then
    echo "::error::update_pins.py --list-tools listed no tools" >&2
    return 1
  fi
  return "$fail"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
