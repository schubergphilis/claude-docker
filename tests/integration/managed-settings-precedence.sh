#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# managed-settings-precedence.sh — does the image's Claude Code let the
# --egress-lock managed settings (run.sh: gen_egress_managed_settings) beat
# every way a project can move the model traffic? (openspec: api-egress-policy)
#
# Runs the image with --network none and two loopback logging servers. In the
# endpoint suite the managed settings point Claude Code at :9001, each project
# override at :9002. In the proxy suite Claude Code talks to the auth-proxy
# sidecar's name (mapped to loopback, :9002) through squid's place (:9001), as
# under --api, and each override tries to skip the proxy. A case passes when a
# model request reaches :9001 and none reaches :9002. A control run of every
# case without the managed settings must reach :9002, or the harness proves
# nothing. The managed run also fails on any backend switch
# in the bundle that the managed settings don't pin off. CI runs it on every
# PR, the claude-code pin refresh included: precedence and the set of backends
# are Claude Code's, not ours.
#
# Usage: IMAGE=<tag> bash tests/integration/managed-settings-precedence.sh
#
# The in-container half is precedence-in-container.sh, mounted into the image.

# The settings run.sh writes, from run.sh itself. Loopback bypasses the proxy
# (EGRESS_NO_PROXY), so the endpoint suite never meets :9003, and the proxy
# suite's endpoint is the sidecar's name, as under --api.
gen() {
  ANTHROPIC_BASE_URL="$1" bash -c \
    'source "$1"; gen_egress_managed_settings "$2"' _ "$REPO/run.sh" "$2"
}

write_managed_settings() {
  gen http://127.0.0.1:9001 http://127.0.0.1:9003 >"$TMP/managed-endpoint.json"
  gen http://claude-docker-api-proxy:9002 http://127.0.0.1:9001 >"$TMP/managed-proxy.json"
}

run_mode() {
  local mode="$1" suite="$2" mount=()
  [ "$mode" = "managed" ] && mount=(-v "$TMP/managed-$suite.json:/etc/claude-code/managed-settings.json:ro")
  docker run --rm --network none --user 0 --entrypoint bash \
    -v "$REPO/tests/integration/precedence-in-container.sh:/precedence.sh:ro" ${mount[@]+"${mount[@]}"} \
    "$IMAGE" /precedence.sh "$mode" "$suite"
}

main() {
  set -euo pipefail
  IMAGE="${IMAGE:-claude-code:local}"
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  TMP=$(mktemp -d)
  trap 'rm -rf "$TMP"' EXIT
  write_managed_settings
  # The four runs share nothing (each container has --network none and its
  # own loopback servers), so they run in parallel; each one's output is
  # printed whole, in a fixed order, once it has finished.
  local rc=0 suite mode i pids=() outs=()
  for suite in endpoint proxy; do
    for mode in control managed; do
      run_mode "$mode" "$suite" >"$TMP/out-$mode-$suite" 2>&1 &
      pids+=("$!")
      outs+=("$TMP/out-$mode-$suite")
    done
  done
  for i in "${!pids[@]}"; do
    wait "${pids[$i]}" || rc=1
    cat "${outs[$i]}"
  done
  [ "$rc" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
  return "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
