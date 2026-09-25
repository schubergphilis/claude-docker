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
set -euo pipefail
python3 update_pins.py --audit
# Capture the tool list into a variable BEFORE looping: a process
# substitution `done < <(cmd)` does NOT propagate cmd's non-zero exit
# under `set -e`, so a fail-closed --list-tools (e.g. a missing pin)
# would silently yield an empty loop and skip every signature check
# (fail-open). `$(...)` assignment, by contrast, DOES abort the script
# under `set -e`, so the here-string consumer below is fail-closed.
tools=$(python3 update_pins.py --list-tools)
# Columns: name, probe, version_re, version, kind, ref (ref is the npm package).
while IFS=$'\t' read -r _name _probe _re ver kind pkg; do
  [ "$kind" = npm ] || continue
  scratch=$(mktemp -d)
  ( cd "$scratch" && npm init -y >/dev/null \
    && npm install --ignore-scripts --no-audit --no-fund --silent "${pkg}@${ver}" \
    && npm audit signatures )
done <<< "$tools"
