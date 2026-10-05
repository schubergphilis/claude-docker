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

# Soak gate: update_pins.py --audit owns the per-tool soak windows.
run_soak_audit() {
  python3 update_pins.py --audit
}

# Registry rows: name, probe, version_re, version, kind, ref (tab-separated).
list_tools() {
  python3 update_pins.py --list-tools
}

# Signature-check one --list-tools row; non-npm rows are skipped.
audit_tool() {
  local name=$1 ver=$2 kind=$3 pkg=$4 scratch rc=0
  # Tab is IFS whitespace, so an empty column collapses and shifts the rest
  # left: the last field is then empty. Fail closed instead of mis-skipping.
  [ -n "$pkg" ] || { echo "::error::malformed --list-tools row for $name" >&2; return 1; }
  [ "$kind" = npm ] || return 0
  [ -n "$ver" ] || { echo "::error::no pinned version for $name" >&2; return 1; }
  scratch=$(mktemp -d) || return 1
  # Subshell keeps the cd local; explicit `||`/`&&` so a failing step fails
  # the tool without relying on `set -e`, and the scratch dir (a full
  # node_modules) is removed whatever the outcome.
  (
    cd "$scratch" || exit 1
    npm init -y >/dev/null \
      && npm install --ignore-scripts --no-audit --no-fund --silent "${pkg}@${ver}" \
      && npm audit signatures
  ) || rc=$?
  rm -rf "$scratch"
  return "$rc"
}

main() {
  set -euo pipefail
  local tools name ver kind pkg
  run_soak_audit || return
  # Capture the tool list into a variable BEFORE looping: a process
  # substitution `done < <(cmd)` does NOT propagate cmd's non-zero exit
  # under `set -e`, so a fail-closed --list-tools (e.g. a missing pin)
  # would silently yield an empty loop and skip every signature check
  # (fail-open). A `$(...)` assignment, by contrast, carries cmd's exit
  # status, so the explicit `|| return` keeps the here-string consumer
  # below fail-closed even where `set -e` is suspended (e.g. `main || x`).
  # (An empty list reaches the loop as one empty row, which audit_tool
  # rejects as malformed, so that fails closed too.)
  tools=$(list_tools) || return
  # Columns: name, probe, version_re, version, kind, ref (ref is the npm package).
  while IFS=$'\t' read -r name _ _ ver kind pkg; do
    audit_tool "$name" "$ver" "$kind" "$pkg" || return 1
  done <<< "$tools"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
