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
# Usage: IMAGE=<tag> bash tests/smoke/egress.sh [--gh | --endpoint-port | --allowlist]
#   --gh             also start the gh auth-proxy sidecar (fake token) and
#                    assert that GitHub traffic flows agent → squid → gh
#                    sidecar → GitHub, with the token injected (GitHub answers
#                    "Bad credentials", not anonymous).
#   --endpoint-port  use an endpoint on a port other than 80/443
#                    (https://github.com:22, whose sshd reliably accepts the
#                    tunnel) and assert squid allows that port for the endpoint
#                    only. Runs with --api-direct: only then does the agent
#                    itself dial the endpoint.
#   --allowlist      add --egress-allowlist with a file listing example.org
#                    and .github.com, plus --gh and --tfe: listed hosts are
#                    reachable, unlisted ones and --tfe's host refused, and
#                    both DNS probes passed (the session started). With
#                    EGRESS_SMOKE_GH_TOKEN set to a real token, a git clone
#                    goes through the gh sidecar. Also records the DNS probe's
#                    codes on this engine (design D7, task 0.5).
# The other cells use --api, so model traffic goes agent → squid → auth-proxy
# sidecar → endpoint.
#
# Linux-only (util-linux `script` supplies the PTY that run.sh's `-it` needs).

log() { echo "[egress-smoke] $*"; }
die() { echo "[egress-smoke] FAIL: $*" >&2; exit 1; }

parse_args() {
  local arg
  IMAGE="${IMAGE:-claude-code:local}"
  WITH_GH=0
  WITH_ALLOWLIST=0
  ENDPOINT_PORT=""
  for arg in "$@"; do
    case "$arg" in
      --gh) WITH_GH=1 ;;
      --endpoint-port) ENDPOINT_PORT=22 ;;
      --allowlist) WITH_ALLOWLIST=1 ;;
      *) die "unknown argument '$arg'" ;;
    esac
  done
}

cleanup() {
  if [ -n "${TMPROOT:-}" ]; then
    rm -rf "$TMPROOT"
  fi
}

# Under $HOME for the same reason as smoke.sh / run.sh: it is bind-mounted.
# The fake gateway is example.com: it answers HTTPS, and the session never
# sends it a model request (CLAUDE_DOCKER_TEST_ENTRY replaces claude). The
# session's log lands in $TMPROOT/state, not the runner's real state dir.
# ANTHROPIC_API_KEY too: entrypoint.sh must pre-approve it in the --ephemeral
# (so fresh) ~/.claude.json, or Claude Code's first-run connectivity check
# against api.anthropic.com ends the session.
setup_workspace() {
  REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  RUN_SH="$REPO/run.sh"
  mkdir -p "$HOME/.cache/claude-docker" || die "cannot create $HOME/.cache/claude-docker"
  TMPROOT=$(mktemp -d "$HOME/.cache/claude-docker/egress-smoke.XXXXXX") || die "mktemp failed"
  # Right after mktemp, so a failing mkdir or cp below can't leak the dir.
  trap cleanup EXIT
  WS="$TMPROOT/egress"
  mkdir -p "$WS" || die "cannot create $WS"
  cp "$REPO/tests/smoke/assert-in-container.sh" "$WS/assert-in-container.sh" || die "cannot stage assert-in-container.sh"
  chmod +x "$WS/assert-in-container.sh"
  api_env=(CLAUDE_DOCKER_IMAGE="$IMAGE" ANTHROPIC_AUTH_TOKEN=sk-fake-egress-smoke
           ANTHROPIC_API_KEY=sk-fake-egress-smoke-api-key-0123456789
           XDG_STATE_HOME="$TMPROOT/state")
}

# One endpoint the lock must refuse: run.sh exits non-zero, before any
# container resource exists, naming $2.
refused() {
  local url="$1" needle="$2" out base=()
  [ -n "$url" ] && base=(ANTHROPIC_BASE_URL="$url")
  if out=$(env "${api_env[@]}" ${base[@]+"${base[@]}"} \
           bash "$RUN_SH" --api --egress-lock --ephemeral "$WS" </dev/null 2>&1); then
    die "run.sh started an --egress-lock session with ANTHROPIC_BASE_URL='$url'"
  fi
  printf '%s\n' "$out" | grep -q -- "$needle" || die "ANTHROPIC_BASE_URL='$url' rejected without '$needle': $out"
}

# 1. Endpoints the lock refuses abort startup: none, a model provider's own
#    host, and one that tries to smuggle squid config.
check_refused_endpoints() {
  refused "" "--egress-lock needs ANTHROPIC_BASE_URL"
  refused "https://api.anthropic.com" "points at one"
  refused "https://example.com
http_access allow all" "is not a valid hostname"
  log "PASS: missing, provider and injected endpoints abort startup"
}

# 2. The session, under util-linux `script` for the PTY run.sh's `-it` needs.
run_session() {
  local entry envs quoted rc rcfile="$TMPROOT/rc" api_flag=--api api_proxy=1 managed_url
  endpoint_host=example.com endpoint_url=https://example.com
  if [ -n "$ENDPOINT_PORT" ]; then
    endpoint_host=github.com endpoint_url="https://github.com:$ENDPOINT_PORT"
    api_flag=--api-direct api_proxy=0
  fi
  # The URL the managed settings pin: the auth-proxy sidecar's under --api.
  managed_url="$endpoint_url"
  [ "$api_proxy" = "1" ] && managed_url=http://claude-docker-api-proxy:8080
  API_PROXY="$api_proxy"
  local gh_check="$WITH_GH" clone=0 gh_token=ghp_fakeEgressSmokeToken000000000000000000
  if [ "$WITH_ALLOWLIST" = "1" ]; then
    # A real token can't give "Bad credentials", but can clone.
    if [ -n "${EGRESS_SMOKE_GH_TOKEN:-}" ]; then
      gh_token="$EGRESS_SMOKE_GH_TOKEN" gh_check=0 clone=1
    else
      gh_check=1
    fi
  fi
  entry="EXPECT_EGRESS=1 EXPECT_EGRESS_ALLOWLIST=$WITH_ALLOWLIST EXPECT_EGRESS_GH_CLONE=$clone EXPECT_EGRESS_GH=$gh_check EXPECT_EGRESS_API_PROXY=$api_proxy EXPECT_EGRESS_ENDPOINT_PORT=$ENDPOINT_PORT EXPECT_EGRESS_MANAGED_URL=$managed_url EXPECT_UID=$(id -u) EXPECT_GID=$(id -g) /workspaces/egress/assert-in-container.sh"
  flags=("$api_flag" --egress-lock --ephemeral)
  envs=("${api_env[@]}"
        ANTHROPIC_BASE_URL="$endpoint_url"
        CLAUDE_DOCKER_TEST_ENTRY="$entry")
  if [ "$WITH_GH" = "1" ] || [ "$WITH_ALLOWLIST" = "1" ]; then
    flags+=(--gh)
    envs+=(GH_TOKEN="$gh_token")
  fi
  if [ "$WITH_ALLOWLIST" = "1" ]; then
    # Outside the workspace ($WS is $TMPROOT/egress), as run.sh requires.
    ALLOWLIST="$TMPROOT/team.allow"
    printf '# smoke\nexample.org\n.github.com\n' >"$ALLOWLIST"
    flags+=(--tfe "--egress-allowlist=$ALLOWLIST")
  fi

  transcript="$TMPROOT/transcript.txt"
  quoted="$(printf '%q ' env "${envs[@]}" bash "$RUN_SH" "${flags[@]}" "$WS"); echo \$? > $(printf '%q' "$rcfile")"
  log "Cell: flags=${flags[*]} image=$IMAGE"
  SHELL=/bin/bash timeout -k 10 300 script -qec "$quoted" "$transcript" >/dev/null 2>&1 || true
  cat "$transcript"
  rc=$(cat "$rcfile" 2>/dev/null || echo 124)
  [ "$rc" = "0" ] || die "run.sh session exited $rc"
  grep -q "RESULT: PASS" "$transcript" || die "in-container assertions did not report PASS"
}

# 3. Host-side: the startup banner, the denied summary and the saved evidence.
assert_evidence() {
  local logf proxy_image
  grep -q "egress proxy 'claude-egress-proxy-" "$transcript" \
    || die "run.sh did not announce the egress proxy"
  grep -q "egress proxy blocked:.*api.anthropic.com" "$transcript" \
    || die "end-of-session summary does not name api.anthropic.com"
  logf=$(find "$TMPROOT/state/claude-docker/egress" -name "*.log" 2>/dev/null | head -1)
  [ -n "$logf" ] && [ -f "${logf%.log}.meta" ] || die "no egress log/meta saved under $TMPROOT/state"
  # run.sh checks the copy against the engine: "saved" means `logs` succeeded
  # and squid's startup line came back with it.
  grep -q "egress log saved to " "$transcript" \
    || die "run.sh reported the egress log missing or incomplete, not saved"
  grep -q "TCP_TUNNEL/200 .* CONNECT example.org:443" "$logf" || die "saved log lacks the example.org CONNECT"
  grep -q "^endpoint=$endpoint_host\$" "${logf%.log}.meta" || die "meta does not name the endpoint"
  # Under --api the agent's model traffic reaches squid as plain HTTP to the
  # auth-proxy sidecar; the sidecar's own connection to the endpoint doesn't
  # pass through squid.
  if [ "$API_PROXY" = "1" ]; then
    grep -q " http://claude-docker-api-proxy:8080/" "$logf" \
      || die "saved log lacks the agent's request to the --api auth-proxy sidecar"
  fi
  # squid runs from its own image, built by run.sh, never from the agent image.
  proxy_image=$(sed -n 's/^proxy_image=//p' "${logf%.log}.meta")
  case "$proxy_image" in
    claude-docker-egress-proxy:*) ;;
    *) die "meta names proxy image '$proxy_image', not run.sh's claude-docker-egress-proxy" ;;
  esac
  ! docker run --rm --entrypoint sh "$IMAGE" -c 'command -v squid' >/dev/null 2>&1 \
    || die "the agent image still contains squid"
  if [ -n "$ENDPOINT_PORT" ]; then
    # The squid log is the evidence for the allow: a tunnel, not a deny.
    grep -q "TCP_TUNNEL/200 .* CONNECT github.com:$ENDPOINT_PORT " "$logf" \
      || die "saved log lacks the allowed github.com:$ENDPOINT_PORT CONNECT"
    ! grep -q "egress proxy blocked:.* github.com:$ENDPOINT_PORT " "$transcript" \
      || die "end-of-session summary lists the endpoint's own port as blocked"
    grep -q "egress proxy blocked:.* example.org:$ENDPOINT_PORT " "$transcript" \
      || die "end-of-session summary does not list example.org:$ENDPOINT_PORT"
  fi
  if [ "$WITH_ALLOWLIST" = "1" ]; then
    assert_allowlist_evidence "$logf"
  fi
  log "PASS: startup banner, denied summary, saved log"
}

# --egress-allowlist evidence: the file's resolved path and hash in the meta,
# and the config squid ran with, owner-only, next to the log.
assert_allowlist_evidence() {
  local meta="${1%.log}.meta" conf="${1%.log}.conf"
  grep -qx "allowlist_file=$ALLOWLIST" "$meta" || die "meta does not name the allowlist file"
  grep -qx "allowlist_sha256=$(sha256sum "$ALLOWLIST" | cut -d' ' -f1)" "$meta" \
    || die "meta's allowlist_sha256 does not match the file"
  grep -q "^allowlist_add_hosts=.*github.com:" "$meta" || die "meta lacks the --gh sidecar's add-hosts"
  [ -f "$conf" ] || die "no squid config saved next to the log"
  [ "$(stat -c %a "$conf")" = 600 ] || die "the saved squid config is not owner-only"
  grep -q "^http_access deny all\$" "$conf" || die "the saved config does not end in deny all"
  grep -q "egress proxy blocked:.*app.terraform.io" "$transcript" \
    || die "the denied summary does not name --tfe's unlisted host"
  log "PASS: allowlist evidence (file, hash, add-hosts, saved config)"
}

# Task 0.5: the code the DNS probe gets on this engine. On an internal
# network it must be one run.sh accepts; against a resolver that can't be
# reached it must not be (a timeout never passes).
check_probe_codes() {
  local net="claude-egress-smoke-probe-$$" code closed
  closed=$(bash -c 'source "$1"; printf "%s" "$EGRESS_DNS_CLOSED_CODES"' _ "$RUN_SH")
  probe() {
    docker run --rm "$@" --entrypoint node "$IMAGE" -e \
      'new (require("dns").promises.Resolver)({timeout:3000,tries:1}).resolve4("example.org").then(a=>console.log("ADDR "+a[0]),e=>console.log("ERR "+e.code))' \
      2>/dev/null | tail -1
  }
  docker network create --internal "$net" >/dev/null || die "cannot create $net"
  code=$(probe --network "$net") || true
  docker network rm "$net" >/dev/null 2>&1 || true
  log "DNS probe on an internal network ($(docker version --format '{{.Server.Version}}' 2>/dev/null)): $code"
  case " $closed " in *" ${code#ERR } "*) ;; *) die "internal-network probe got '$code', not one of: $closed" ;; esac
  code=$(probe --network none --dns 192.0.2.1) || true
  log "DNS probe against an unreachable resolver: $code"
  case "$code" in
    "ERR "*) case " $closed " in *" ${code#ERR } "*) die "an unreachable resolver gives '$code', which run.sh accepts as closed" ;; esac ;;
    *) die "an unreachable resolver gave '$code'" ;;
  esac
  log "PASS: DNS probe codes"
}

# Only this session's resources: another session's live sidecar on the same
# host is not a leftover (openspec/changes/archive/2026-10-09-egress-lock/tasks.md 6.4).
# The id comes from the startup banner.
assert_teardown() {
  local sid name leftover=""
  sid=$(grep -o "egress proxy 'claude-egress-proxy-[A-Za-z0-9]*'" "$transcript" \
        | head -1 | sed -e "s#.*claude-egress-proxy-##" -e "s#'\$##") || true
  [ -n "$sid" ] || die "no session id in the startup banner"
  for name in "claude-egress-proxy-$sid" "claude-auth-proxy-$sid" \
              "claude-egress-proxy-$sid-probe-control" "claude-egress-proxy-$sid-probe-check"; do
    [ -z "$(docker ps -aq --filter "name=^${name}\$")" ] || leftover+=" $name"
  done
  for name in "claude-egress-$sid" "claude-egress-out-$sid" "claude-auth-$sid"; do
    [ -z "$(docker network ls -q --filter "name=^${name}\$")" ] || leftover+=" network:$name"
  done
  [ -z "$leftover" ] || die "teardown left resources behind:$leftover"
  log "PASS: no resources of session $sid left"
}

main() {
  set -euo pipefail
  parse_args "$@"
  setup_workspace
  check_refused_endpoints
  [ "$WITH_ALLOWLIST" = "1" ] && check_probe_codes
  run_session
  assert_evidence
  assert_teardown
  log "Cell PASS: flags=${flags[*]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
