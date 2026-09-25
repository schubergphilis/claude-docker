#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# Runtime version check, run from the repo root by ci.yml's `docker-build` job:
# every pinned CLI in the claude-docker:ci image reports its pinned version.
# The tool set, each tool's version probe, and the rule for reading a version
# out of that probe all come from update_pins.py's registry, so a newly pinned
# tool is covered without editing this file.
set -euo pipefail
# Capture before looping. --list-tools is fail-closed, and `$(...)`
# propagates its non-zero exit under `set -e` where a
# `done < <(cmd)` process substitution would not.
tools=$(python3 update_pins.py --list-tools)
fail=0
while IFS=$'\t' read -r name probe version_re pinned _kind _ref; do
  read -ra argv <<< "$probe"
  # One conditional chain, not three statements: an unrunnable tool,
  # an unreadable version and a wrong version must each land in the
  # `else` instead of tripping `set -e` and skipping the tools after
  # it. $version_re is deliberately unquoted — quoting the right-hand
  # side of =~ makes bash match it as a literal string, not a regex.
  # </dev/null keeps docker away from the loop's here-string.
  if actual=$(docker run --rm claude-docker:ci "${argv[@]}" </dev/null) \
     && [[ "$actual" =~ $version_re ]] \
     && [ "${BASH_REMATCH[1]}" = "$pinned" ]; then
    status=PASS
  else
    status=FAIL
    fail=1
  fi
  echo "  ${status}  ${name}  pinned=${pinned}  reported=${actual:-<probe failed>}"
  [ "$status" = PASS ] \
    || echo "::error::${name}: pinned ${pinned}, image reported '${actual:-<probe failed>}'"
done <<< "$tools"
exit "$fail"
