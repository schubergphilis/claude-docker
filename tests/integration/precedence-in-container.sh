#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# precedence-in-container.sh — the in-container half of
# managed-settings-precedence.sh, which mounts it into the image and runs it
# as root with --network none.
#
# Starts two loopback logging servers (:9001, :9002), then runs each case's
# `claude -p` and counts the model requests each server got. See the host
# script's header for what the suites and modes prove.
#
# Usage: precedence-in-container.sh <managed|control> <endpoint|proxy>

# Where run.sh mounts the managed settings; a variable so the BATS tests can
# point it elsewhere.
MANAGED_SETTINGS="${MANAGED_SETTINGS:-/etc/claude-code/managed-settings.json}"

over='"ANTHROPIC_BASE_URL":"http://127.0.0.1:9002"'

start_servers() {
  cat >"$W/srv.js" <<'JS'
const http = require('http'), fs = require('fs');
const [port, log] = process.argv.slice(2);
http.createServer((req, res) => {
  fs.appendFileSync(log, `${req.method} ${req.url}\n`);
  req.resume();
  req.on('end', () => {
    res.writeHead(401, {'content-type': 'application/json'});
    res.end('{"type":"error","error":{"type":"authentication_error","message":"precedence test"}}');
  });
}).listen(Number(port), '127.0.0.1');
JS
  node "$W/srv.js" 9001 "$W/9001.log" & s1=$!
  node "$W/srv.js" 9002 "$W/9002.log" & s2=$!
  trap 'kill "$s1" "$s2" 2>/dev/null' EXIT
  sleep 1
}

# The env run.sh gives the agent container. In the proxy suite :9001 stands in
# for squid: it gets the absolute-form request a proxied client sends.
set_run_env() {
  if [ "$suite" = "proxy" ]; then
    echo "127.0.0.1 claude-docker-api-proxy" >>/etc/hosts
    run_env=(ANTHROPIC_BASE_URL=http://claude-docker-api-proxy:9002
      http_proxy=http://127.0.0.1:9001 https_proxy=http://127.0.0.1:9001
      HTTP_PROXY=http://127.0.0.1:9001 HTTPS_PROXY=http://127.0.0.1:9001
      "no_proxy=localhost,127.0.0.1,::1" "NO_PROXY=localhost,127.0.0.1,::1")
  else
    run_env=(ANTHROPIC_BASE_URL=http://127.0.0.1:9001)
  fi
}

# case <name> <settings file under .claude/, or --settings> <env json>
check() {
  local name="$1" where="$2" env="$3" dir="$W/$1" hits1 hits2
  mkdir -p "$dir/proj/.claude" "$dir/home"
  local args=()
  if [ "$where" = "--settings" ]; then
    printf '{"env":{%s}}' "$env" >"$dir/flag.json"
    args=(--settings "$dir/flag.json")
  else
    printf '{"env":{%s}}' "$env" >"$dir/proj/.claude/$where"
  fi
  : >"$W/9001.log"; : >"$W/9002.log"
  (cd "$dir/proj" && exec env -i HOME="$dir/home" PATH="$PATH" ANTHROPIC_API_KEY=sk-fake \
     "${run_env[@]}" CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
     claude ${args[@]+"${args[@]}"} -p hi >"$dir/out" 2>&1) &
  local pid=$!
  # Stop at the first model request, wherever it lands; 60s budget.
  for _ in $(seq 60); do
    grep -q '^POST' "$W/9001.log" "$W/9002.log" && break
    sleep 1
  done
  sleep 2
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  hits1=$(grep -c '^POST' "$W/9001.log"); hits2=$(grep -c '^POST' "$W/9002.log")
  if [ "$mode" = "control" ]; then
    [ "$hits2" -gt 0 ] && echo "PASS: control $name: the override wins without managed settings (:9002 $hits2)" \
      || { echo "FAIL: control $name: the override did not win (:9001 $hits1, :9002 $hits2), so the cases prove nothing"; fails=$((fails + 1)); }
  elif [ "$hits1" -gt 0 ] && [ "$hits2" -eq 0 ]; then
    echo "PASS: $name: managed settings win (:9001 $hits1, :9002 0)"
  else
    echo "FAIL: $name: :9001 $hits1, :9002 $hits2 ($(head -c 200 "$dir/out" | tr '\n' ' '))"
    fails=$((fails + 1))
  fi
}

# Every CLAUDE_CODE_USE_* switch the bundle knows is either pinned off in the
# managed settings or listed here as picking no model backend. A Claude Code
# release that adds a backend fails here until gen_egress_managed_settings
# pins it, instead of leaving a route the cases below don't cover.
not_backends=" CCR_V2 COWORK_PLUGINS NATIVE_FILE_SEARCH POWERSHELL_TOOL "
check_switches() {
  local pkg sw n=0
  pkg="$(npm root -g)/@anthropic-ai/claude-code"
  for sw in $(grep -raohE 'CLAUDE_CODE_USE_[A-Z0-9_]+' "$pkg" | sort -u); do
    n=$((n + 1))
    case "$not_backends" in *" ${sw#CLAUDE_CODE_USE_} "*) continue ;; esac
    if jq -e --arg k "$sw" '.env[$k] == "0"' "$MANAGED_SETTINGS" >/dev/null; then
      echo "PASS: switch $sw is pinned off"
    else
      echo "FAIL: switch $sw is not pinned off: add it to gen_egress_managed_settings, or to not_backends if it picks no backend"
      fails=$((fails + 1))
    fi
  done
  # Guard against a vacuous pass if the bundle moves out of $pkg.
  [ "$n" -gt 0 ] || { echo "FAIL: no CLAUDE_CODE_USE_* switch found under $pkg"; fails=$((fails + 1)); }
}

# Both modes run every case: the control proves each override, backends
# included, really moves the traffic without managed settings.
run_cases() {
  if [ "$suite" = "proxy" ]; then
    check no-proxy    settings.json '"NO_PROXY":"claude-docker-api-proxy","no_proxy":"claude-docker-api-proxy"'
    check empty-proxy settings.json '"HTTP_PROXY":"","http_proxy":"","HTTPS_PROXY":"","https_proxy":""'
    return
  fi
  [ "$mode" = "managed" ] && check_switches
  check settings       settings.json       "$over"
  check settings-local settings.local.json "$over"
  check settings-flag  --settings          "$over"
  check bedrock settings.json '"CLAUDE_CODE_USE_BEDROCK":"1","CLAUDE_CODE_SKIP_BEDROCK_AUTH":"1","AWS_REGION":"us-east-1","ANTHROPIC_BEDROCK_BASE_URL":"http://127.0.0.1:9002"'
  check vertex  settings.json '"CLAUDE_CODE_USE_VERTEX":"1","CLAUDE_CODE_SKIP_VERTEX_AUTH":"1","ANTHROPIC_VERTEX_PROJECT_ID":"p","CLOUD_ML_REGION":"us-east5","ANTHROPIC_VERTEX_BASE_URL":"http://127.0.0.1:9002"'
  check foundry settings.json '"CLAUDE_CODE_USE_FOUNDRY":"1","CLAUDE_CODE_SKIP_FOUNDRY_AUTH":"1","ANTHROPIC_FOUNDRY_API_KEY":"x","ANTHROPIC_FOUNDRY_BASE_URL":"http://127.0.0.1:9002"'
  check anthropic-aws settings.json '"CLAUDE_CODE_USE_ANTHROPIC_AWS":"1","CLAUDE_CODE_SKIP_ANTHROPIC_AWS_AUTH":"1","AWS_REGION":"us-east-1","ANTHROPIC_AWS_BASE_URL":"http://127.0.0.1:9002"'
  check anthropic-google-cloud settings.json '"CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD":"1","CLAUDE_CODE_SKIP_ANTHROPIC_GOOGLE_CLOUD_AUTH":"1","ANTHROPIC_GOOGLE_CLOUD_PROJECT":"p","ANTHROPIC_GOOGLE_CLOUD_LOCATION":"global","ANTHROPIC_GOOGLE_CLOUD_BASE_URL":"http://127.0.0.1:9002"'
  check mantle settings.json '"CLAUDE_CODE_USE_MANTLE":"1","CLAUDE_CODE_SKIP_MANTLE_AUTH":"1","AWS_REGION":"us-east-1","ANTHROPIC_BEDROCK_MANTLE_BASE_URL":"http://127.0.0.1:9002"'
  check gateway settings.json '"CLAUDE_CODE_USE_GATEWAY":"1","ANTHROPIC_AUTH_TOKEN":"x",'"$over"
}

main() {
  set -uo pipefail
  mode="$1"   # managed | control
  suite="$2"  # endpoint | proxy
  W=/tmp/precedence
  fails=0
  mkdir -p "$W"
  start_servers
  set_run_env
  run_cases
  [ "$fails" -eq 0 ]
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
