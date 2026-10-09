#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# egress.sh — smoke cell for --egress-lock (openspec: api-egress-policy).
# Drives run.sh like smoke.sh does, but with the real docker (no shim): run.sh
# also starts the squid sidecar, the internal network and, with --gh, the gh
# sidecar, and this cell asserts on their teardown too. The in-container half
# is assert-in-container.sh with EXPECT_EGRESS=1.
#
# Usage: IMAGE=<tag> bash smoke/egress.sh [--gh | --endpoint-port]
#   --gh             also start the gh auth-proxy sidecar (fake token) and
#                    assert that GitHub traffic flows agent → squid → gh
#                    sidecar → GitHub, with the token injected (GitHub answers
#                    "Bad credentials", not anonymous).
#   --endpoint-port  use an endpoint on a port other than 80/443
#                    (https://github.com:22, whose sshd reliably accepts the
#                    tunnel) and assert squid allows that port for the endpoint
#                    only.
#
# Linux-only (util-linux `script` supplies the PTY that run.sh's `-it` needs).
set -euo pipefail

IMAGE="${IMAGE:-claude-code:local}"
WITH_GH=0
ENDPOINT_PORT=""
for arg in "$@"; do
  case "$arg" in
    --gh) WITH_GH=1 ;;
    --endpoint-port) ENDPOINT_PORT=22 ;;
    *) echo "egress.sh: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

log() { echo "[egress-smoke] $*"; }
die() { echo "[egress-smoke] FAIL: $*" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/.." && pwd)"
# Under $HOME for the same reason as smoke.sh / run.sh: it is bind-mounted.
mkdir -p "$HOME/.cache/claude-docker"
TMPROOT=$(mktemp -d "$HOME/.cache/claude-docker/egress-smoke.XXXXXX")
trap 'rm -rf "$TMPROOT"' EXIT
WS="$TMPROOT/egress"
mkdir -p "$WS"
cp "$REPO/smoke/assert-in-container.sh" "$WS/assert-in-container.sh"
chmod +x "$WS/assert-in-container.sh"

# The fake gateway is example.com: it answers HTTPS, and the session never
# sends it a model request (CLAUDE_DOCKER_TEST_ENTRY replaces claude). The
# session's log lands in $TMPROOT/state, not the runner's real state dir.
api_env=(CLAUDE_DOCKER_IMAGE="$IMAGE" ANTHROPIC_AUTH_TOKEN=sk-fake-egress-smoke
         XDG_STATE_HOME="$TMPROOT/state")

# 1. Endpoints the lock refuses abort startup before any container resource
#    exists: none, a model provider's own host, and one that tries to smuggle
#    squid config.
refused() {
  local url="$1" needle="$2" out base=()
  [ -n "$url" ] && base=(ANTHROPIC_BASE_URL="$url")
  if out=$(env "${api_env[@]}" ${base[@]+"${base[@]}"} \
           bash "$REPO/run.sh" --api --egress-lock --ephemeral "$WS" </dev/null 2>&1); then
    die "run.sh started an --egress-lock session with ANTHROPIC_BASE_URL='$url'"
  fi
  printf '%s\n' "$out" | grep -q -- "$needle" || die "ANTHROPIC_BASE_URL='$url' rejected without '$needle': $out"
}
refused "" "--egress-lock needs ANTHROPIC_BASE_URL"
refused "https://api.anthropic.com" "points at one"
refused "https://example.com
http_access allow all" "is not a valid hostname"
log "PASS: missing, provider and injected endpoints abort startup"

# 2. The session.
endpoint_host=example.com endpoint_url=https://example.com
if [ -n "$ENDPOINT_PORT" ]; then
  endpoint_host=github.com endpoint_url="https://github.com:$ENDPOINT_PORT"
fi
entry="EXPECT_EGRESS=1 EXPECT_EGRESS_GH=$WITH_GH EXPECT_EGRESS_ENDPOINT_PORT=$ENDPOINT_PORT EXPECT_UID=$(id -u) EXPECT_GID=$(id -g) /workspaces/egress/assert-in-container.sh"
flags=(--api --egress-lock --ephemeral)
envs=("${api_env[@]}"
      ANTHROPIC_BASE_URL="$endpoint_url"
      CLAUDE_DOCKER_TEST_ENTRY="$entry")
if [ "$WITH_GH" = "1" ]; then
  flags+=(--gh)
  envs+=(GH_TOKEN=ghp_fakeEgressSmokeToken000000000000000000)
fi

rcfile="$TMPROOT/rc"
transcript="$TMPROOT/transcript.txt"
quoted="$(printf '%q ' env "${envs[@]}" bash "$REPO/run.sh" "${flags[@]}" "$WS"); echo \$? > $(printf '%q' "$rcfile")"
log "Cell: flags=${flags[*]} image=$IMAGE"
SHELL=/bin/bash timeout -k 10 300 script -qec "$quoted" "$transcript" >/dev/null 2>&1 || true
cat "$transcript"
rc=$(cat "$rcfile" 2>/dev/null || echo 124)
[ "$rc" = "0" ] || die "run.sh session exited $rc"
grep -q "RESULT: PASS" "$transcript" || die "in-container assertions did not report PASS"

# 3. Host-side: the startup banner, the denied summary and the saved evidence.
grep -q "egress proxy 'claude-egress-proxy-" "$transcript" \
  || die "run.sh did not announce the egress proxy"
grep -q "egress proxy blocked:.*api.anthropic.com" "$transcript" \
  || die "end-of-session summary does not name api.anthropic.com"
logf=$(find "$TMPROOT/state/claude-docker/egress" -name "*.log" 2>/dev/null | head -1)
[ -n "$logf" ] && [ -f "${logf%.log}.meta" ] || die "no egress log/meta saved under $TMPROOT/state"
grep -q "TCP_TUNNEL/200 .* CONNECT example.org:443" "$logf" || die "saved log lacks the example.org CONNECT"
grep -q "^endpoint=$endpoint_host\$" "${logf%.log}.meta" || die "meta does not name the endpoint"
if [ -n "$ENDPOINT_PORT" ]; then
  # The squid log is the evidence for the allow: a tunnel, not a deny.
  grep -q "TCP_TUNNEL/200 .* CONNECT github.com:$ENDPOINT_PORT " "$logf" \
    || die "saved log lacks the allowed github.com:$ENDPOINT_PORT CONNECT"
  ! grep -q "egress proxy blocked:.* github.com:$ENDPOINT_PORT " "$transcript" \
    || die "end-of-session summary lists the endpoint's own port as blocked"
  grep -q "egress proxy blocked:.* example.org:$ENDPOINT_PORT " "$transcript" \
    || die "end-of-session summary does not list example.org:$ENDPOINT_PORT"
fi
log "PASS: startup banner, denied summary, saved log"

# Only this session's resources: another session's live sidecar on the same
# host is not a leftover (tasks.md 6.4). The id comes from the startup banner.
sid=$(grep -o "egress proxy 'claude-egress-proxy-[A-Za-z0-9]*'" "$transcript" \
      | head -1 | sed -e "s#.*claude-egress-proxy-##" -e "s#'\$##") || true
[ -n "$sid" ] || die "no session id in the startup banner"
leftover=""
for name in "claude-egress-proxy-$sid" "claude-gh-proxy-$sid"; do
  [ -z "$(docker ps -aq --filter "name=^${name}\$")" ] || leftover+=" $name"
done
for name in "claude-egress-$sid" "claude-egress-out-$sid" "claude-gh-$sid"; do
  [ -z "$(docker network ls -q --filter "name=^${name}\$")" ] || leftover+=" network:$name"
done
[ -z "$leftover" ] || die "teardown left resources behind:$leftover"
log "PASS: no resources of session $sid left"

log "Cell PASS: flags=${flags[*]}"
