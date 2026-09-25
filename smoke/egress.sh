#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# egress.sh — smoke cell for --egress-allowlist (openspec: egress-allowlist).
# Drives run.sh like smoke.sh does, but with the real docker (no shim): run.sh
# also starts the squid sidecar, the internal network and, with --gh, the gh
# sidecar, and this cell asserts on their teardown too. The in-container half
# is assert-in-container.sh with EXPECT_EGRESS=1.
#
# Usage: IMAGE=<tag> bash smoke/egress.sh [--gh]
#   --gh   also start the gh auth-proxy sidecar (fake token) and assert that
#          GitHub traffic flows agent → squid → gh sidecar → GitHub.
#
# Linux-only (util-linux `script` supplies the PTY that run.sh's `-it` needs).
set -euo pipefail

IMAGE="${IMAGE:-claude-code:local}"
WITH_GH=0
for arg in "$@"; do
  case "$arg" in
    --gh) WITH_GH=1 ;;
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

# 1. An entry that tries to smuggle squid config is rejected before any
#    container resource exists.
if out=$(CLAUDE_DOCKER_IMAGE="$IMAGE" \
         CLAUDE_DOCKER_EGRESS_ALLOW=$'example.com\nhttp_access allow all' \
         bash "$REPO/run.sh" --egress-allowlist --ephemeral "$WS" </dev/null 2>&1); then
  die "run.sh accepted an injection attempt in CLAUDE_DOCKER_EGRESS_ALLOW"
fi
printf '%s\n' "$out" | grep -q "invalid --egress-allowlist entry" \
  || die "injection attempt rejected without naming the entry: $out"
log "PASS: invalid allowlist entry aborts startup"

# 2. The session. api.anthropic.com is listed again on purpose: a user entry
#    that duplicates a built-in one must not break squid's config.
entry="EXPECT_EGRESS=1 EXPECT_EGRESS_GH=$WITH_GH EXPECT_UID=$(id -u) EXPECT_GID=$(id -g) /workspaces/egress/assert-in-container.sh"
flags=(--egress-allowlist --ephemeral)
envs=(CLAUDE_DOCKER_IMAGE="$IMAGE"
      CLAUDE_DOCKER_EGRESS_ALLOW="example.com,localhost api.anthropic.com"
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

# 3. Host-side: the startup banner, the end-of-session denied summary, and
#    teardown.
grep -q "egress allowlist proxy 'claude-egress-proxy-" "$transcript" \
  || die "run.sh did not announce the egress proxy"
grep -q "egress allowlist blocked:.*example.org.*CLAUDE_DOCKER_EGRESS_ALLOW" "$transcript" \
  || die "end-of-session summary does not name example.org and CLAUDE_DOCKER_EGRESS_ALLOW"
log "PASS: startup banner and denied-host summary"

leftover=$(docker ps -aq --filter "name=^claude-egress-" --filter "name=^claude-gh-"; \
           docker network ls -q --filter "name=^claude-egress-"; \
           docker network ls -q --filter "name=^claude-gh-")
[ -z "$leftover" ] || die "teardown left resources behind: $leftover"
log "PASS: no claude-egress-* / claude-gh-* resources left"

log "Cell PASS: flags=${flags[*]}"
