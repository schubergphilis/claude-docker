#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# npm-pinned tools supply-chain audit, run from the repo root by ci.yml's
# `validate` job. For EVERY npm-pinned tool enforce two policies: (1) tarball
# signed by npm's keyring over dist.integrity (`npm audit signatures`), (2) soak
# since publish (per-tool window: 7 days, 1 day for claude-code) so loud
# supply-chain attacks get yanked before we ingest. The soak gate is enforced
# by update_pins.py --audit, which is the single source of truth for soak logic
# (including each tool's window). The tool list is the kind == npm rows of
# update_pins.py --list-tools so CI never re-implements generator logic.

# Signature-check one --list-tools row; non-npm rows are skipped.
audit_tool() {
  local name=$1 ver=$2 kind=$3 pkg=$4 rc=0
  # Tab is IFS whitespace, so an empty column collapses and shifts the rest
  # left: the last field is then empty. Fail closed instead of mis-skipping.
  [ -n "$pkg" ] || { echo "::error::malformed --list-tools row for $name" >&2; return 1; }
  [ "$kind" = npm ] || return 0
  [ -n "$ver" ] || { echo "::error::no pinned version for $name" >&2; return 1; }
  # Global, so main's EXIT trap can remove it if a signal cuts the run short.
  SCRATCH=$(mktemp -d) || return 1
  # Subshell keeps the cd local; explicit `||`/`&&` so a failing step fails
  # the tool without relying on `set -e`, and the scratch dir (a full
  # node_modules) is removed whatever the outcome.
  (
    cd "$SCRATCH" || exit 1
    npm init -y >/dev/null \
      && npm install --ignore-scripts --no-audit --no-fund --silent "${pkg}@${ver}" \
      && npm audit signatures
  ) || rc=$?
  rm -rf "$SCRATCH"
  SCRATCH=""
  return "$rc"
}

main() {
  set -euo pipefail
  local tools name ver kind pkg
  trap 'rm -rf "${SCRATCH:-}"' EXIT
  # Soak gate: update_pins.py --audit owns the per-tool soak windows.
  python3 update_pins.py --audit || return
  # Capture the list BEFORE looping: `done < <(cmd)` drops cmd's exit status,
  # so a fail-closed --list-tools would yield an empty loop and skip every
  # signature check. `$(...)` keeps it, and `|| return` holds even where
  # `set -e` is suspended. An empty list reaches the loop as one empty row,
  # which audit_tool rejects as malformed.
  tools=$(python3 update_pins.py --list-tools) || return
  # Columns: name, probe, version_re, version, kind, ref (ref is the npm package).
  while IFS=$'\t' read -r name _ _ ver kind pkg; do
    audit_tool "$name" "$ver" "$kind" "$pkg" || return 1
  done <<< "$tools"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
