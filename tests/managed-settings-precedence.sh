#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# managed-settings-precedence.sh — does the image's Claude Code let the
# --egress-lock managed settings (run.sh: gen_egress_managed_settings) beat
# every way a project can move the model traffic? (openspec: api-egress-policy)
#
# Runs the image with --network none and two loopback logging servers: the
# managed settings point Claude Code at :9001, each project override at :9002.
# A case passes when a model request reaches :9001 and none reaches :9002. A
# control run without the managed settings must reach :9002, or the harness
# proves nothing. Re-run it when the claude-code pin moves: precedence and the
# set of backends are Claude Code's, not ours.
#
# Usage: IMAGE=<tag> bash tests/managed-settings-precedence.sh
set -euo pipefail

IMAGE="${IMAGE:-claude-code:local}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The settings run.sh writes, from run.sh itself.
ANTHROPIC_BASE_URL=http://127.0.0.1:9001 bash -c \
  'source "$1"; gen_egress_managed_settings' _ "$REPO/run.sh" >"$TMP/managed-settings.json"

cat >"$TMP/in-container.sh" <<'IN'
#!/usr/bin/env bash
set -uo pipefail
mode="$1"   # managed | control
W=/tmp/precedence
mkdir -p "$W"
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

over='"ANTHROPIC_BASE_URL":"http://127.0.0.1:9002"'
fails=0
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
     ANTHROPIC_BASE_URL=http://127.0.0.1:9001 CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
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

if [ "$mode" = "control" ]; then
  check settings settings.json "$over"
else
  check settings       settings.json       "$over"
  check settings-local settings.local.json "$over"
  check settings-flag  --settings          "$over"
  check bedrock settings.json '"CLAUDE_CODE_USE_BEDROCK":"1","CLAUDE_CODE_SKIP_BEDROCK_AUTH":"1","AWS_REGION":"us-east-1","ANTHROPIC_BEDROCK_BASE_URL":"http://127.0.0.1:9002"'
  check vertex  settings.json '"CLAUDE_CODE_USE_VERTEX":"1","CLAUDE_CODE_SKIP_VERTEX_AUTH":"1","ANTHROPIC_VERTEX_PROJECT_ID":"p","CLOUD_ML_REGION":"us-east5","ANTHROPIC_VERTEX_BASE_URL":"http://127.0.0.1:9002"'
  check foundry settings.json '"CLAUDE_CODE_USE_FOUNDRY":"1","CLAUDE_CODE_SKIP_FOUNDRY_AUTH":"1","ANTHROPIC_FOUNDRY_API_KEY":"x","ANTHROPIC_FOUNDRY_BASE_URL":"http://127.0.0.1:9002"'
fi
exit "$fails"
IN
chmod +x "$TMP/in-container.sh"

run_mode() {
  local mode="$1" mount=()
  [ "$mode" = "managed" ] && mount=(-v "$TMP/managed-settings.json:/etc/claude-code/managed-settings.json:ro")
  docker run --rm --network none --user 0 --entrypoint bash \
    -v "$TMP/in-container.sh:/precedence.sh:ro" ${mount[@]+"${mount[@]}"} \
    "$IMAGE" /precedence.sh "$mode"
}

rc=0
run_mode control || rc=1
run_mode managed || rc=1
[ "$rc" = 0 ] && echo "RESULT: PASS" || echo "RESULT: FAIL"
exit "$rc"
