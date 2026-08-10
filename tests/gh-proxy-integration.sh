#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# gh-proxy-integration.sh — CI-runnable, credential-free integration harness for
# the GitHub auth-proxy sidecar (openspec/changes/gh-auth-proxy-sidecar). Unlike
# smoke/smoke.sh (which reconstructs `docker run` itself and never touches
# run.sh), this harness drives `run.sh` end-to-end: the entire sidecar lifecycle
# (network, sidecar, CA, Caddyfile, teardown) lives in run.sh, not in a
# standalone docker invocation, so it has to be exercised through the real
# entrypoint. A mock GitHub upstream (the same pinned Caddy image, running as a
# plain-HTTP echo server) stands in for github.com/api.github.com/
# uploads.github.com via run.sh's test-only CLAUDE_DOCKER_GH_UPSTREAM hook, so
# no GitHub credentials are ever needed.
#
# Uses a FAKE token throughout (ghp_fake...); never reads or forwards a real
# host credential.
#
# Assertion → task mapping (see openspec/changes/gh-auth-proxy-sidecar/tasks.md):
#   4.2  placeholder GH_TOKEN, token absent from /proc/1/environ, curl reaches
#        api.github.com with the injected Bearer header (no -k — proves CA
#        trust), gh's Go resolver honours --add-host, git's smart-HTTP request
#        reaches the mock with the injected Basic header.
#   4.3  default policy blocks DELETE /repos/{o}/{r} (403 + policy body, never
#        reaches the mock); benign requests pass; a CLAUDE_DOCKER_GH_POLICY
#        extension is enforced.
#   4.4  sidecar audit log has structured method/path/status entries, never
#        contains the token, and the name run.sh prints matches the running
#        container.
#   4.5  two concurrent sessions get distinct networks/sidecars/CA roots, both
#        work, and teardown leaves no claude-gh-* resources.
#   4.6  --gh-direct forwards the real token with no sidecar; --gh with no
#        discoverable host token starts no sidecar and stays silent; --gh
#        --gh-direct together is rejected; a bad CLAUDE_DOCKER_PROXY_IMAGE
#        fails closed (no agent container, no leftovers).
#   #22  release-asset HEAD probes leave the sidecar with no Authorization
#        header while the GET on the same path keeps the injected Basic one,
#        and UV_SYSTEM_CERTS=1 reaches the agent container.
#
# Known deviations / assumptions (see the final report to the orchestrator for
# the full list):
#   - `git ls-remote` against the mock is expected to reach it (proven via
#     mock/sidecar logs) but then fail client-side: the mock is a generic JSON
#     echo, not a git-smart-HTTP server. Task 4.2's wording ("git clone...
#     succeeds") assumes a git-aware mock; this harness deliberately trades
#     that for a much simpler, more robust mock and verifies transport+auth
#     via logs instead. Documented, not silently downgraded.
#   - The CLAUDE_DOCKER_GH_POLICY snippet syntax is inferred (a `@name { }`
#     matcher block + `respond`) — run.sh's own snippet-import mechanics were
#     not available to read against at the time this harness was written.
#   - Caddy REDACTS credential headers (Authorization, Cookie, …) in access
#     logs by default — which is exactly what keeps the sidecar's audit log
#     token-free per spec. The MOCK's Caddyfile deliberately opts back in
#     (`servers { log_credentials }`) so its access log doubles as the
#     evidence trail for header injection on requests we can't inspect the
#     body of (git).
#   - `--gh` with no token is forced deterministically by shadowing any real
#     host `gh` with an always-failing stub prepended to PATH (removing gh's
#     directory instead could also remove docker — on typical CI runners both
#     live in /usr/bin).
#
# This script intentionally does NOT use `set -e`: several scenarios assert a
# non-zero exit from run.sh, and letting the harness itself abort on the first
# expected failure would defeat the point. Every fallible command is checked
# explicitly instead.
set -uo pipefail

# ---------------------------------------------------------------------------
# Preflight — skip gracefully without docker; fail fast on other missing deps.
# ---------------------------------------------------------------------------

if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
  echo "SKIP: no working docker daemon in this environment — gh-proxy-integration.sh requires docker (not a failure)."
  exit 0
fi

if ! command -v script >/dev/null 2>&1; then
  echo "FATAL: 'script' not found (util-linux on Linux; ships with macOS) — required to give run.sh's 'docker run -it' a PTY in a non-interactive shell." >&2
  exit 1
fi

TARGET_IMAGE="${CLAUDE_DOCKER_IMAGE:-claude-code:local}"
if ! docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1; then
  echo "FATAL: image '$TARGET_IMAGE' not found — build it first (docker build -t claude-code:local .). CI is expected to build it before running this harness." >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_SH="$(cd "$SCRIPT_DIR/.." && pwd)/run.sh"
if [ ! -f "$RUN_SH" ]; then
  echo "FATAL: run.sh not found at $RUN_SH" >&2
  exit 1
fi

# Pinned mock image — deliberately the SAME digest-pinned Caddy image the
# sidecar itself uses (see run.sh's PROXY_IMAGE default), reused here as a
# generic plain-HTTP echo server. Not read from CLAUDE_DOCKER_PROXY_IMAGE:
# that env var is reserved below for the 4.6 bad-image scenario, which must
# only affect the SIDECAR run.sh starts, never this harness's own mock.
MOCK_IMAGE="caddy:2.11.4@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9"

FAKE1="ghp_fakeMainSessionToken0000000000000001"
FAKE_A="ghp_fakeConcurrentSessionTokenA00000001"
FAKE_B="ghp_fakeConcurrentSessionTokenB00000002"
FAKE_DIRECT="ghp_fakeGhDirectToken000000000000000001"

# ---------------------------------------------------------------------------
# Result bookkeeping
# ---------------------------------------------------------------------------

TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

record_pass() { echo "PASS: $1"; TOTAL_PASS=$((TOTAL_PASS + 1)); }
record_fail() { echo "FAIL: $1"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }
record_skip() { echo "SKIP: $1"; TOTAL_SKIP=$((TOTAL_SKIP + 1)); }

# Folds an in-container assert script's results.txt (PASS:/FAIL:/SKIP: lines)
# into this harness's own counters, prefixed with a session label. A missing
# file is itself a FAIL — the in-container script never ran to completion —
# EXCEPT for the badimage-sentinel scenario, which checks the file's absence
# directly and must never call this helper.
ingest_results_file() {
  local file="$1" label="$2" line
  if [ ! -f "$file" ]; then
    record_fail "$label: results file missing ($file) — in-container assert script did not run to completion"
    return
  fi
  while IFS= read -r line; do
    case "$line" in
      PASS:*) record_pass "$label: ${line#PASS: }" ;;
      FAIL:*) record_fail "$label: ${line#FAIL: }" ;;
      SKIP:*) record_skip "$label: ${line#SKIP: }" ;;
    esac
  done < "$file"
}

# ---------------------------------------------------------------------------
# Scratch dir + cleanup trap
# ---------------------------------------------------------------------------

# Staged under $HOME, NOT $TMPDIR//tmp, for the same reason run.sh stages
# there: macOS docker VMs (Docker Desktop shares /tmp, Colima doesn't; neither
# shares /var/folders) only reliably share $HOME, and this dir is bind-mounted
# into the mock (Caddyfile) — an unshared source path materializes as an empty
# directory inside the VM and the file mount fails with ENOTDIR.
SCRATCH_ROOT="$HOME/.cache/claude-docker"
mkdir -p "$SCRATCH_ROOT"
SCRATCH=$(mktemp -d "$SCRATCH_ROOT/ghtest.XXXXXX")
MOCK_CID=""
BG_PIDS=()
CLEANUP_DONE=0

# Removes STOPPED claude-gh-* sidecars and unused networks — mirrors run.sh's
# own startup prune (same prefix, same stopped-only rationale). CRITICAL: never
# touches a RUNNING claude-gh-proxy-* container, because that almost certainly
# belongs to a concurrent live `claude-docker --gh` session on this same host
# (e.g. the one you may be running this from) — force-removing it would sever
# that session's GitHub access mid-flight. Network rm is best-effort and fails
# harmlessly on an in-use network (a live session's), so only genuinely orphaned
# networks are removed. Called at pre-flight (so a prior crashed run of THIS
# harness can't confuse discovery) and from the exit trap (backstop only).
sweep_stale_claude_gh() {
  docker ps -aq --filter "name=^claude-gh-proxy-" \
      --filter "status=exited" --filter "status=created" --filter "status=dead" \
      2>/dev/null | while IFS= read -r cid; do
    [ -n "$cid" ] && docker rm -f "$cid" >/dev/null 2>&1
  done
  docker network ls -q --filter "name=^claude-gh-" 2>/dev/null | while IFS= read -r nid; do
    [ -n "$nid" ] && docker network rm "$nid" >/dev/null 2>&1
  done
  return 0
}

# shellcheck disable=SC2329  # invoked indirectly via `trap cleanup EXIT INT TERM` below
cleanup() {
  [ "$CLEANUP_DONE" = "1" ] && return
  CLEANUP_DONE=1
  local pid
  # Guarded: macOS /bin/bash is 3.2, where expanding an empty array under
  # set -u is fatal (same convention as run.sh).
  if [ "${#BG_PIDS[@]}" -gt 0 ]; then
    for pid in "${BG_PIDS[@]}"; do
      [ -n "$pid" ] && kill "$pid" >/dev/null 2>&1
    done
  fi
  wait 2>/dev/null
  [ -n "$MOCK_CID" ] && docker rm -f "$MOCK_CID" >/dev/null 2>&1
  sweep_stale_claude_gh
  # Keep the scratch dir (session transcripts, captured sidecar/mock logs,
  # results files) whenever anything failed — it's the only debugging
  # evidence, and several artifacts in it can't be regenerated after the
  # --rm containers are gone.
  if [ "$TOTAL_FAIL" -gt 0 ]; then
    echo "Failures recorded — keeping scratch dir for debugging: $SCRATCH"
  else
    [ -n "$SCRATCH" ] && rm -rf "$SCRATCH"
  fi
}
trap cleanup EXIT INT TERM

echo "Pre-flight: sweeping any stale claude-gh-* resources from a previous run..."
sweep_stale_claude_gh

# Baseline: claude-gh-* resources that already exist AFTER the sweep — i.e. a
# concurrent live `claude-docker --gh` session's network/sidecar on this host
# (the sweep leaves running sidecars alone). They legitimately persist for the
# whole run, so teardown assertions must judge "clean" as "nothing NEW beyond
# this baseline", never "nothing at all". Space-padded for whole-word `case`
# membership tests.
BASELINE_NETS=" $(docker network ls --filter 'name=claude-gh-' --format '{{.Name}}' 2>/dev/null | tr '\n' ' ')"
BASELINE_SIDECARS=" $(docker ps -a --filter 'name=claude-gh-proxy-' --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')"
[ "$(printf '%s' "$BASELINE_NETS" | tr -d ' ')" != "" ] \
  && echo "Pre-flight: detected pre-existing claude-gh-* resources (likely a live --gh session) — excluding from teardown checks:$BASELINE_NETS"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Runs "$@" under a PTY: run.sh's final step is `docker run -it`, which errors
# ("the input device is not a TTY") without one when stdin/stdout aren't a
# terminal — the normal case for a CI job or a backgrounded shell. Portable
# across script(1) flavors: util-linux takes `-c <command>`, BSD/macOS takes
# the command as trailing argv and never propagates its exit status — so the
# status always travels via a file written by the wrapped shell, and the
# flavor only decides argv shape. A timeout guards against hangs where one
# exists (GNU/BSD `timeout`, coreutils `gtimeout`); its absence (stock macOS
# pre-13) just means no hang guard, not a hard dependency. `-k 10 300` is the
# flag spelling both GNU and BSD timeout accept. SHELL is pinned to bash so
# the inner shell parses the same quoting `printf %q` just produced. The full
# session transcript lands in $1 for later grepping (e.g. the sidecar name
# run.sh prints); the live copy is discarded.
run_wrapped() {
  local logfile="$1"; shift
  local quoted rcfile rc
  rcfile="$SCRATCH/rc.$$.$RANDOM"
  quoted="$(printf '%q ' "$@"); echo \$? > $(printf '%q' "$rcfile")"
  if script --version 2>/dev/null | grep -q util-linux; then
    set -- script -qec "$quoted" "$logfile"
  else
    set -- script -q "$logfile" /bin/bash -c "$quoted"
  fi
  if command -v timeout >/dev/null 2>&1; then
    set -- timeout -k 10 300 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    set -- gtimeout -k 10 300 "$@"
  fi
  SHELL=/bin/bash "$@" >/dev/null 2>&1
  rc=$(cat "$rcfile" 2>/dev/null)
  rm -f "$rcfile"
  # Missing rc file means the wrapped shell never got to write it (timeout
  # kill, script(1) failure) — report it as a timeout-style failure.
  return "${rc:-124}"
}

# sha256 of a file, portable: sha256sum (Linux) vs shasum -a 256 (macOS).
hash_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

wait_for_file() {
  local path="$1" timeout="$2" i=0
  while [ "$i" -lt "$timeout" ]; do
    [ -f "$path" ] && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

wait_for_container_running() {
  local name="$1" timeout="$2" i=0
  while [ "$i" -lt "$timeout" ]; do
    if docker ps --filter "name=^${name}$" --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      return 0
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Space-separated list of claude-gh-* resources that exist now but were NOT in
# the pre-existing baseline — i.e. resources this harness created and failed to
# clean up. Empty means clean. A concurrent live session (in the baseline) is
# correctly ignored.
new_claude_gh_leftovers() {
  local n c out=""
  for n in $(docker network ls --filter 'name=claude-gh-' --format '{{.Name}}' 2>/dev/null); do
    case "$BASELINE_NETS" in *" $n "*) ;; *) out="$out net:$n" ;; esac
  done
  for c in $(docker ps -a --filter 'name=claude-gh-proxy-' --format '{{.Names}}' 2>/dev/null); do
    case "$BASELINE_SIDECARS" in *" $c "*) ;; *) out="$out container:$c" ;; esac
  done
  printf '%s' "${out# }"
}

no_new_claude_gh_resources() {
  [ -z "$(new_claude_gh_leftovers)" ]
}

wait_for_absence_claude_gh() {
  local timeout="$1" i=0
  while [ "$i" -lt "$timeout" ]; do
    no_new_claude_gh_resources && return 0
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Polls `docker network ls` for a claude-gh-* network not already named in
# $2 (space-separated). Session ids are mktemp suffixes chosen by run.sh
# itself and unknowable ahead of time, so discovery is the only option; the
# pre-flight sweep above plus this exclude-list keep concurrent-session
# discovery (phase 2) unambiguous without relying on timing alone.
poll_new_network() {
  local timeout="$1" exclude="$2" i=0 candidates line
  while [ "$i" -lt "$timeout" ]; do
    candidates=$(docker network ls --filter "name=claude-gh-" --format '{{.Name}}' 2>/dev/null)
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      case " $exclude " in
        *" $line "*) continue ;;
      esac
      printf '%s\n' "$line"
      return 0
    done <<<"$candidates"
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# Space-delimited snapshot of the claude-gh-* networks that exist RIGHT NOW.
# Captured immediately before launching a run.sh and fed to poll_new_network as
# the exclude list, so a network stranded by an earlier interrupted run (which
# the pre-flight sweep cannot remove while a wedged sidecar still holds it)
# can never be misidentified as this session's freshly-created network — the
# failure mode that otherwise cascades into wrong-network mock attachment.
snapshot_claude_gh_nets() {
  docker network ls --filter "name=claude-gh-" --format '{{.Name}}' 2>/dev/null | tr '\n' ' '
}

# Builds a PATH whose first entry holds an always-failing `gh` stub, for the
# "no discoverable token" 4.6 scenario — run.sh's fallback calls
# `gh auth token` on the HOST, and a stub that exits 1 forces that fallback
# to yield nothing, deterministically, whatever the CI runner has installed.
# Shadowing beats removing gh's directory from PATH: on typical runners gh
# and docker both live in /usr/bin, and hiding that directory would break
# run.sh's runtime discovery instead of testing the no-token path.
make_no_gh_path() {
  local shim_dir="$SCRATCH/no-gh-bin"
  mkdir -p "$shim_dir"
  printf '#!/bin/sh\nexit 1\n' > "$shim_dir/gh"
  chmod +x "$shim_dir/gh"
  printf '%s' "$shim_dir:$PATH"
}

# Generates the in-container assertion script for one session. Parameters are
# baked in as literal shell assignments (NOT forwarded via docker -e): run.sh
# only forwards a fixed allowlist of env vars into the agent container per
# opt-in flag, with no generic passthrough, so a file written into the
# already-bind-mounted workspace is the only channel available to this
# harness for handing parameters to code running inside the container.
gen_assert_script() {
  local out="$1" mode="$2" fake="$3" policy_ext="$4"
  local ws_name results done_marker release_marker sentinel
  ws_name=$(basename "$(dirname "$out")")
  results="/workspaces/${ws_name}/results.txt"
  done_marker="/workspaces/${ws_name}/checks-done"
  release_marker="/workspaces/${ws_name}/release"
  sentinel="/workspaces/${ws_name}/should-not-exist"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -uo pipefail\n'
    printf "MODE='%s'\n" "$mode"
    printf "FAKE_TOKEN='%s'\n" "$fake"
    printf "POLICY_EXT='%s'\n" "$policy_ext"
    printf "RESULTS='%s'\n" "$results"
    printf "DONE_MARKER='%s'\n" "$done_marker"
    printf "RELEASE_MARKER='%s'\n" "$release_marker"
    printf "SENTINEL='%s'\n" "$sentinel"
    cat <<'BODY'
: > "$RESULTS"
pass() { printf 'PASS: %s\n' "$1" >> "$RESULTS"; }
fail() { printf 'FAIL: %s\n' "$1" >> "$RESULTS"; }
skip() { printf 'SKIP: %s\n' "$1" >> "$RESULTS"; }

# Bounded wait for the harness to say it has captured everything it needs
# (sidecar/mock logs, CA roots) before we let the container exit — those are
# only readable while the --rm containers are still alive. The timeout is a
# safety valve in case the harness process itself dies mid-session.
wait_for_release() {
  local i=0
  while [ ! -f "$RELEASE_MARKER" ] && [ "$i" -lt 150 ]; do
    sleep 0.2
    i=$((i + 1))
  done
}

run_main_checks() {
  if [ "${GH_TOKEN:-}" = "claude-docker-proxy" ]; then
    pass "4.2 placeholder GH_TOKEN in agent env (GH_TOKEN=claude-docker-proxy)"
  else
    fail "4.2 placeholder GH_TOKEN: expected 'claude-docker-proxy', got '${GH_TOKEN:-<unset>}'"
  fi

  # PID 1 is this script itself (CLAUDE_DOCKER_TEST_ENTRY is "exec bash
  # <this file>", and the outer `sh -c` execs into it), so /proc/1/environ is
  # our own environment — reading it needs no special privilege.
  if grep -aq -- "$FAKE_TOKEN" /proc/1/environ 2>/dev/null; then
    fail "4.2 fake host token found in /proc/1/environ (token isolation broken)"
  else
    pass "4.2 fake host token absent from /proc/1/environ"
  fi

  local i=0 curl_ok=0 curl_out="" curl_err=""
  while [ "$i" -lt 40 ]; do
    if curl_out=$(curl -sS --max-time 5 https://api.github.com/rate_limit 2>/tmp/gh_curl_err.$$); then
      curl_ok=1
      break
    fi
    curl_err=$(cat /tmp/gh_curl_err.$$ 2>/dev/null)
    i=$((i + 1))
    sleep 1
  done
  rm -f /tmp/gh_curl_err.$$
  if [ "$curl_ok" -eq 1 ]; then
    pass "4.2 curl reached api.github.com through the sidecar without -k (attempt $((i + 1)); TLS verified against the session CA)"
    case "$curl_out" in
      *"Bearer $FAKE_TOKEN"*) pass "4.2 sidecar injected the real Authorization: Bearer <token> header (mock echoed it back)" ;;
      *) fail "4.2 mock response missing the injected Bearer header: $curl_out" ;;
    esac
    case "$curl_out" in
      *'"method":"GET"'*) pass "4.2 mock echo confirms method GET arrived" ;;
      *) fail "4.2 mock echo missing method GET: $curl_out" ;;
    esac
  else
    fail "4.2 curl never reached api.github.com within the retry budget: $curl_err"
  fi

  # gh is a Go binary with its own resolver; design.md calls out that this
  # must be asserted explicitly rather than assumed to follow --add-host the
  # same way libc's getaddrinfo (used by curl/git) does.
  if command -v gh >/dev/null 2>&1; then
    local gh_out gh_err
    if gh_out=$(gh api /rate_limit 2>/tmp/gh_gh_err.$$); then
      case "$gh_out" in
        *"Bearer $FAKE_TOKEN"*) pass "4.2 gh (Go resolver) reached api.github.com via --add-host and got the injected Bearer header" ;;
        *) fail "4.2 gh reached api.github.com but the response is missing the injected Bearer header: $gh_out" ;;
      esac
    else
      gh_err=$(cat /tmp/gh_gh_err.$$ 2>/dev/null)
      fail "4.2 gh api /rate_limit failed: $gh_err"
    fi
    rm -f /tmp/gh_gh_err.$$
    if [ "$(gh auth token 2>/dev/null)" = "claude-docker-proxy" ]; then
      pass "4.2 gh auth token returns the placeholder, not the real token"
    else
      fail "4.2 gh auth token did not return the placeholder"
    fi
  else
    skip "4.2 gh not on PATH in this image; cannot assert Go-resolver equivalence for --add-host"
  fi

  # git's smart-HTTP discovery request is expected to reach the mock (proven
  # host-side via mock/sidecar logs — see the harness's own report), but git
  # itself is expected to then fail: the mock is a generic JSON echo, not a
  # git-protocol-aware server, so it can't return a valid smart-HTTP response
  # body. That's intentional; this check doesn't gate on git's own exit code.
  timeout 15 git ls-remote https://github.com/o/r >/tmp/gh_git_out.$$ 2>/tmp/gh_git_err.$$
  pass "4.2 git ls-remote against github.com attempted through the sidecar (arrival + Basic header verified host-side via mock/sidecar logs)"
  rm -f /tmp/gh_git_out.$$ /tmp/gh_git_err.$$

  if curl -sS --max-time 10 -o /dev/null -w '%{http_code}' https://api.github.com/repos/o/r 2>/dev/null | grep -q '^200$'; then
    pass "4.3 benign GET /repos/o/r passes (200)"
  else
    fail "4.3 benign GET /repos/o/r did not return 200"
  fi

  local delete_code
  delete_code=$(curl -sS --max-time 10 -o /tmp/gh_delete_body.$$ -w '%{http_code}' -X DELETE https://api.github.com/repos/o/r 2>/dev/null)
  if [ "$delete_code" = "403" ] && grep -q "claude-docker gh-proxy policy" /tmp/gh_delete_body.$$; then
    pass "4.3 default policy blocks DELETE /repos/o/r (403, policy body present)"
  else
    fail "4.3 default policy did not block DELETE /repos/o/r as expected (code=$delete_code body=$(cat /tmp/gh_delete_body.$$ 2>/dev/null))"
  fi
  rm -f /tmp/gh_delete_body.$$

  if [ "$POLICY_EXT" = "1" ]; then
    local refs_code
    refs_code=$(curl -sS --max-time 10 -o /dev/null -w '%{http_code}' -X DELETE https://api.github.com/repos/o/r/git/refs/heads/foo 2>/dev/null)
    if [ "$refs_code" = "403" ]; then
      pass "4.3 CLAUDE_DOCKER_GH_POLICY extension blocks DELETE .../git/refs/heads/foo (403)"
    else
      fail "4.3 CLAUDE_DOCKER_GH_POLICY extension did not block DELETE .../git/refs/heads/foo (code=$refs_code)"
    fi
  fi

  # --- issue #22: release-asset HEAD probes must leave the sidecar anonymous ---
  # Real GitHub routes a release-asset HEAD that carries ANY Authorization
  # header to a legacy objects.githubusercontent.com pre-signed URL that then
  # 401s, which is what breaks uv (it probes with HEAD before GET). That routing
  # is GitHub-side and cannot be reproduced against a mock, so what the harness
  # asserts here is the sidecar's half of the contract — which credential each
  # method carries — plus the env var that lets uv trust the session CA at all.
  # The HEAD is asserted host-side from the mock's access log: a HEAD response
  # carries no body, so the echo cannot report its own headers.
  if [ "${UV_SYSTEM_CERTS:-}" = "1" ]; then
    pass "#22 UV_SYSTEM_CERTS=1 present in the agent env (uv reads the OS trust store)"
  else
    fail "#22 UV_SYSTEM_CERTS: expected '1', got '${UV_SYSTEM_CERTS:-<unset>}' — uv would fail TLS against the intercepted hostnames"
  fi

  local asset_url="https://github.com/o/r/releases/download/v1.0.0/pkg-1.0.0-py3-none-any.whl"
  curl -sS --max-time 10 -I -o /dev/null "$asset_url" 2>/dev/null
  local asset_get
  asset_get=$(curl -sS --max-time 10 "$asset_url" 2>/dev/null)
  case "$asset_get" in
    *'"authorization":"Basic '*) pass "#22 GET on a release-asset path still carries the injected Basic credential" ;;
    *) fail "#22 GET on a release-asset path lost its injected credential: $asset_get" ;;
  esac
}

run_concurrent_check() {
  local i=0 curl_ok=0 curl_out=""
  while [ "$i" -lt 40 ]; do
    if curl_out=$(curl -sS --max-time 5 https://api.github.com/rate_limit 2>/dev/null); then
      curl_ok=1
      break
    fi
    i=$((i + 1))
    sleep 1
  done
  if [ "$curl_ok" -eq 1 ]; then
    case "$curl_out" in
      *"Bearer $FAKE_TOKEN"*) pass "4.5 session reached api.github.com via its own sidecar with its own token copy" ;;
      *) fail "4.5 session reached api.github.com but with the wrong/missing token: $curl_out" ;;
    esac
  else
    fail "4.5 session never reached api.github.com via its sidecar within the retry budget"
  fi
}

case "$MODE" in
  main)
    run_main_checks
    touch "$DONE_MARKER"
    wait_for_release
    ;;
  concurrent)
    run_concurrent_check
    touch "$DONE_MARKER"
    wait_for_release
    ;;
  direct)
    if [ "${GH_TOKEN:-}" = "$FAKE_TOKEN" ]; then
      pass "4.6 --gh-direct forwarded the real (fake) token into the agent container"
    else
      fail "4.6 --gh-direct: GH_TOKEN mismatch, got '${GH_TOKEN:-<unset>}' want '$FAKE_TOKEN'"
    fi
    ;;
  notoken)
    if [ -z "${GH_TOKEN:-}" ]; then
      pass "4.6 --gh with no host token: GH_TOKEN is unset/empty in the agent container"
    else
      fail "4.6 --gh with no host token: GH_TOKEN unexpectedly set to '${GH_TOKEN}'"
    fi
    ;;
  badimage-sentinel)
    # Should never run: if the sidecar fails to start, run.sh must never wire
    # up (let alone start) the agent container. Its existence on the host
    # afterward is itself the FAIL signal the harness checks for.
    touch "$SENTINEL"
    fail "4.6 agent container ran despite the sidecar image being unresolvable (should never have started)"
    ;;
esac
echo "RESULT: assert script finished" >> "$RESULTS"
BODY
  } > "$out"
  chmod +x "$out"
}

# ---------------------------------------------------------------------------
# Mock GitHub upstream — a plain-HTTP echo server on the pinned Caddy image.
# Responds 200 to everything with a JSON body carrying the method, path,
# query, and the Authorization header it received, and logs every request
# (headers included — deliberately, unlike the sidecar's own audit log, which
# must NOT log headers) as JSON to stdout for host-side `docker logs` grepping.
# ---------------------------------------------------------------------------

MOCK_NAME="ghtest-mock-$$-$(date +%s 2>/dev/null || echo 0)"
MOCK_CADDYFILE="$SCRATCH/mock-Caddyfile"
cat > "$MOCK_CADDYFILE" <<'CADDYFILE'
{
	auto_https off
	servers {
		log_credentials
	}
}

:8080 {
	log {
		output stdout
		format json
	}

	respond "{\"method\":\"{http.request.method}\",\"path\":\"{http.request.uri.path}\",\"query\":\"{http.request.uri.query}\",\"authorization\":\"{http.request.header.Authorization}\"}" 200
}
CADDYFILE

echo "Starting mock GitHub upstream ($MOCK_NAME, image $MOCK_IMAGE)..."
MOCK_CID=$(docker run -d --name "$MOCK_NAME" \
  -v "$MOCK_CADDYFILE:/etc/caddy/Caddyfile:ro" \
  "$MOCK_IMAGE" caddy run --config /etc/caddy/Caddyfile --adapter caddyfile 2>"$SCRATCH/mock-start-err.log") || {
  echo "FATAL: could not start the mock GitHub upstream container ($MOCK_IMAGE)" >&2
  cat "$SCRATCH/mock-start-err.log" >&2 2>/dev/null
  exit 1
}
sleep 2
if [ -z "$(docker ps --filter "id=$MOCK_CID" --filter status=running -q)" ]; then
  echo "FATAL: mock GitHub upstream container exited immediately; logs:" >&2
  docker logs "$MOCK_CID" >&2 2>&1
  exit 1
fi

# ===========================================================================
# Phase 1 (tasks 4.2, 4.3, 4.4): one proxied session, functional + policy +
# audit-log checks combined so it only pays for one sidecar/CA/network setup.
# ===========================================================================
echo
echo "=== Phase 1: main proxied session (4.2 token isolation/injection, 4.3 policy, 4.4 audit log) ==="

WS1="$SCRATCH/ghtest-main"
mkdir -p "$WS1"
gen_assert_script "$WS1/assert.sh" main "$FAKE1" "1"

POLICY_FILE="$SCRATCH/gh-policy-snippet.Caddyfile"
cat > "$POLICY_FILE" <<'POLICY'
@claude_docker_test_policy_ext {
	method DELETE
	path_regexp ^/repos/[^/]+/[^/]+/git/refs/.*
}
respond @claude_docker_test_policy_ext "claude-docker gh-proxy policy (test extension): destructive ref deletion blocked" 403
POLICY

LOG1="$SCRATCH/run1.log"
PRE1=$(snapshot_claude_gh_nets)
run_wrapped "$LOG1" env \
  GH_TOKEN="$FAKE1" \
  CLAUDE_DOCKER_RUNTIME=docker \
  CLAUDE_DOCKER_IMAGE="$TARGET_IMAGE" \
  CLAUDE_DOCKER_GH_UPSTREAM="http://ghmock:8080" \
  CLAUDE_DOCKER_GH_POLICY="$POLICY_FILE" \
  CLAUDE_DOCKER_TEST_ENTRY="exec bash /workspaces/ghtest-main/assert.sh" \
  bash "$RUN_SH" --gh "$WS1" &
PID1=$!
BG_PIDS+=("$PID1")

NET1=$(poll_new_network 30 "$PRE1") || NET1=""
SIDECAR1=""
if [ -n "$NET1" ]; then
  record_pass "setup: session network '$NET1' appeared (task 2.1 naming: claude-gh-<id>)"
  if docker network connect --alias ghmock "$NET1" "$MOCK_CID" 2>/dev/null; then
    record_pass "setup: mock attached to $NET1 as alias 'ghmock'"
  else
    record_fail "setup: could not attach mock to $NET1"
  fi
  SIDECAR1="claude-gh-proxy-${NET1#claude-gh-}"
  if wait_for_container_running "$SIDECAR1" 15; then
    record_pass "4.4 sidecar '$SIDECAR1' is running (task 2.1 naming: claude-gh-proxy-<id>)"
  else
    record_fail "4.4 derived sidecar name '$SIDECAR1' never appeared as a running container"
    SIDECAR1=""
  fi
else
  record_fail "setup: session network never appeared within 30s — cannot run phase 1 checks"
fi

if [ -n "$NET1" ]; then
  if wait_for_file "$WS1/checks-done" 90; then
    record_pass "setup: in-container assert script for the main session reached checks-done"
  else
    record_fail "setup: in-container assert script for the main session never reached checks-done (timeout)"
  fi

  # Snapshot logs BEFORE releasing: both containers run --rm and vanish (taking
  # `docker logs` with them) the moment run.sh's own EXIT trap fires.
  [ -n "$SIDECAR1" ] && docker logs "$SIDECAR1" >"$SCRATCH/sidecar1.log" 2>&1
  docker logs "$MOCK_CID" >"$SCRATCH/mock-phase1.log" 2>&1

  docker network disconnect "$NET1" "$MOCK_CID" >/dev/null 2>&1
  touch "$WS1/release"
fi

wait "$PID1"
RC1=$?
if [ "$RC1" -eq 0 ]; then
  record_pass "setup: main session's run.sh exited 0"
else
  record_fail "setup: main session's run.sh exited $RC1 (see $LOG1)"
fi

# Transcript greps only AFTER the session exits: macOS/BSD script(1) buffers
# the typescript and flushes on exit, so a mid-session grep reads an empty
# file even though run.sh already printed the line.
if [ -n "$SIDECAR1" ] && grep -qF "$SIDECAR1" "$LOG1" 2>/dev/null; then
  record_pass "4.4 run.sh printed the sidecar name '$SIDECAR1' before the agent session began"
else
  record_fail "4.4 run.sh's output never mentioned the sidecar name (see $LOG1)"
fi

ingest_results_file "$WS1/results.txt" "main-session"

if [ -f "$SCRATCH/sidecar1.log" ]; then
  if grep -q '"status":200' "$SCRATCH/sidecar1.log"; then
    record_pass "4.4 sidecar audit log contains a structured entry with status 200"
  else
    record_fail "4.4 sidecar audit log missing an expected status-200 entry"
  fi
  delete_default_sidecar_lines=$(grep -F '"uri":"/repos/o/r"' "$SCRATCH/sidecar1.log" 2>/dev/null || true)
  if printf '%s\n' "$delete_default_sidecar_lines" | grep -qF '"method":"DELETE"'; then
    record_pass "4.3/4.4 sidecar audit log recorded the blocked DELETE /repos/o/r"
  else
    record_fail "4.3/4.4 sidecar audit log missing the blocked DELETE /repos/o/r entry"
  fi
  if grep -F "$FAKE1" "$SCRATCH/sidecar1.log" >/dev/null 2>&1; then
    record_fail "4.4 sidecar audit log leaks the fake host token"
  else
    record_pass "4.4 sidecar audit log never contains the fake host token"
  fi
else
  record_fail "4.4 sidecar audit log was never captured (sidecar unresolved or session never started)"
fi

if [ -f "$SCRATCH/mock-phase1.log" ]; then
  delete_default_mock_lines=$(grep -F '"uri":"/repos/o/r"' "$SCRATCH/mock-phase1.log" 2>/dev/null || true)
  if printf '%s\n' "$delete_default_mock_lines" | grep -qF '"method":"DELETE"'; then
    record_fail "4.3 default-policy DELETE /repos/o/r reached the mock upstream (should have been blocked at the sidecar)"
  else
    record_pass "4.3 default-policy DELETE /repos/o/r never reached the mock upstream"
  fi
  if printf '%s\n' "$delete_default_mock_lines" | grep -qF '"method":"GET"'; then
    record_pass "4.3 benign GET /repos/o/r arrived at the mock upstream"
  else
    record_fail "4.3 benign GET /repos/o/r never arrived at the mock upstream"
  fi
  refs_mock_lines=$(grep -F '"uri":"/repos/o/r/git/refs/heads/foo"' "$SCRATCH/mock-phase1.log" 2>/dev/null || true)
  if [ -n "$refs_mock_lines" ]; then
    record_fail "4.3 CLAUDE_DOCKER_GH_POLICY-extended DELETE .../git/refs/heads/foo reached the mock upstream"
  else
    record_pass "4.3 CLAUDE_DOCKER_GH_POLICY-extended DELETE .../git/refs/heads/foo never reached the mock upstream"
  fi
  git_lines=$(grep -F '/o/r/info/refs' "$SCRATCH/mock-phase1.log" 2>/dev/null || true)
  if [ -n "$git_lines" ] && printf '%s\n' "$git_lines" | grep -qF '"Authorization":["Basic'; then
    record_pass "4.2 git ls-remote's smart-HTTP discovery request reached the mock with a Basic Authorization header"
  else
    record_fail "4.2 could not confirm git's request + Basic header arrived at the mock (see $SCRATCH/mock-phase1.log)"
  fi

  # Issue #22, the two halves that matter for regressions: the HEAD must arrive
  # with NO Authorization header (otherwise GitHub's dead-legacy-URL routing
  # comes back), and the GET on the very same path must still arrive WITH the
  # injected Basic header (otherwise the exclusion has leaked past HEAD and
  # widened into traffic that works today). Caddy omits the key entirely when
  # the header is absent, so its presence/absence is a reliable signal.
  asset_uri='"uri":"/o/r/releases/download/v1.0.0/pkg-1.0.0-py3-none-any.whl"'
  asset_head_lines=$(grep -F "$asset_uri" "$SCRATCH/mock-phase1.log" 2>/dev/null | grep -F '"method":"HEAD"' || true)
  if [ -z "$asset_head_lines" ]; then
    record_fail "#22 the release-asset HEAD never reached the mock upstream (see $SCRATCH/mock-phase1.log)"
  elif printf '%s\n' "$asset_head_lines" | grep -qF '"Authorization"'; then
    record_fail "#22 the release-asset HEAD still carried an Authorization header upstream — GitHub would route it to the 401ing objects.githubusercontent.com URL"
  else
    record_pass "#22 the release-asset HEAD reached the upstream with no Authorization header"
  fi
  asset_get_lines=$(grep -F "$asset_uri" "$SCRATCH/mock-phase1.log" 2>/dev/null | grep -F '"method":"GET"' || true)
  if printf '%s\n' "$asset_get_lines" | grep -qF '"Authorization":["Basic'; then
    record_pass "#22 the release-asset GET still reached the upstream with the injected Basic header (exclusion did not widen past HEAD)"
  else
    record_fail "#22 the release-asset GET lost its injected Basic header (see $SCRATCH/mock-phase1.log)"
  fi
else
  record_fail "4.2/4.3 mock upstream log for phase 1 was never captured"
fi

# ===========================================================================
# Phase 2 (task 4.5): two concurrent sessions — isolation + CA difference +
# teardown, with no leftovers once both exit.
# ===========================================================================
echo
echo "=== Phase 2: two concurrent sessions (4.5 isolation, distinct CAs, clean teardown) ==="

WS2A="$SCRATCH/ghtest-concA"
WS2B="$SCRATCH/ghtest-concB"
mkdir -p "$WS2A" "$WS2B"
gen_assert_script "$WS2A/assert.sh" concurrent "$FAKE_A" ""
gen_assert_script "$WS2B/assert.sh" concurrent "$FAKE_B" ""

LOG2A="$SCRATCH/run2a.log"
LOG2B="$SCRATCH/run2b.log"

PRE2A=$(snapshot_claude_gh_nets)
run_wrapped "$LOG2A" env \
  GH_TOKEN="$FAKE_A" \
  CLAUDE_DOCKER_RUNTIME=docker \
  CLAUDE_DOCKER_IMAGE="$TARGET_IMAGE" \
  CLAUDE_DOCKER_GH_UPSTREAM="http://ghmock:8080" \
  CLAUDE_DOCKER_TEST_ENTRY="exec bash /workspaces/ghtest-concA/assert.sh" \
  bash "$RUN_SH" --gh "$WS2A" &
PID2A=$!
BG_PIDS+=("$PID2A")

NET2A=$(poll_new_network 30 "$PRE2A") || NET2A=""
if [ -n "$NET2A" ]; then
  record_pass "4.5 session A got its own network '$NET2A'"
  docker network connect --alias ghmock "$NET2A" "$MOCK_CID" 2>/dev/null \
    || record_fail "4.5 could not attach mock to session A's network"
else
  record_fail "4.5 session A's network never appeared within 30s"
fi

PRE2B=$(snapshot_claude_gh_nets)
run_wrapped "$LOG2B" env \
  GH_TOKEN="$FAKE_B" \
  CLAUDE_DOCKER_RUNTIME=docker \
  CLAUDE_DOCKER_IMAGE="$TARGET_IMAGE" \
  CLAUDE_DOCKER_GH_UPSTREAM="http://ghmock:8080" \
  CLAUDE_DOCKER_TEST_ENTRY="exec bash /workspaces/ghtest-concB/assert.sh" \
  bash "$RUN_SH" --gh "$WS2B" &
PID2B=$!
BG_PIDS+=("$PID2B")

# PRE2B already includes NET2A (captured after A's network appeared), so B's
# discovery excludes both leftovers and session A's network.
NET2B=$(poll_new_network 30 "$PRE2B") || NET2B=""
if [ -n "$NET2B" ] && [ "$NET2B" != "$NET2A" ]; then
  record_pass "4.5 session B got its own, distinct network '$NET2B'"
  docker network connect --alias ghmock "$NET2B" "$MOCK_CID" 2>/dev/null \
    || record_fail "4.5 could not attach mock to session B's network"
else
  record_fail "4.5 session B's network never appeared, or collided with session A's ('$NET2A' vs '$NET2B')"
fi

SIDECAR2A=""
SIDECAR2B=""
[ -n "$NET2A" ] && SIDECAR2A="claude-gh-proxy-${NET2A#claude-gh-}"
[ -n "$NET2B" ] && SIDECAR2B="claude-gh-proxy-${NET2B#claude-gh-}"

ok_a=0
ok_b=0
[ -n "$NET2A" ] && wait_for_file "$WS2A/checks-done" 90 && ok_a=1
[ -n "$NET2B" ] && wait_for_file "$WS2B/checks-done" 90 && ok_b=1

if [ "$ok_a" -eq 1 ] && [ "$ok_b" -eq 1 ]; then
  if wait_for_container_running "$SIDECAR2A" 5 && wait_for_container_running "$SIDECAR2B" 5; then
    record_pass "4.5 both sidecars ('$SIDECAR2A', '$SIDECAR2B') are running at the same time"
  else
    record_fail "4.5 could not confirm both sidecars were simultaneously running"
  fi
  # CA roots must differ — extract while both sidecars are still alive: --rm
  # destroys the container (and its filesystem) the instant its session tears
  # down, so this has to happen inside the release-handshake window.
  if docker cp "${SIDECAR2A}:/data/caddy/pki/authorities/local/root.crt" "$SCRATCH/root2a.crt" 2>/dev/null \
    && docker cp "${SIDECAR2B}:/data/caddy/pki/authorities/local/root.crt" "$SCRATCH/root2b.crt" 2>/dev/null; then
    hash_a=$(hash_file "$SCRATCH/root2a.crt")
    hash_b=$(hash_file "$SCRATCH/root2b.crt")
    if [ -n "$hash_a" ] && [ "$hash_a" != "$hash_b" ]; then
      record_pass "4.5 the two sessions' root CAs differ ($hash_a vs $hash_b)"
    else
      record_fail "4.5 the two sessions' root CAs are identical or unreadable (a=$hash_a b=$hash_b)"
    fi
  else
    record_fail "4.5 could not extract root.crt from one or both sidecars via docker cp"
  fi
else
  record_fail "4.5 one or both concurrent sessions never reached checks-done (session-A-ok=$ok_a session-B-ok=$ok_b)"
fi

[ -n "$NET2A" ] && docker network disconnect "$NET2A" "$MOCK_CID" >/dev/null 2>&1
[ -n "$NET2B" ] && docker network disconnect "$NET2B" "$MOCK_CID" >/dev/null 2>&1
touch "$WS2A/release" "$WS2B/release" 2>/dev/null

wait "$PID2A"
RC2A=$?
wait "$PID2B"
RC2B=$?
if [ "$RC2A" -eq 0 ]; then record_pass "4.5 session A's run.sh exited 0"; else record_fail "4.5 session A's run.sh exited $RC2A"; fi
if [ "$RC2B" -eq 0 ]; then record_pass "4.5 session B's run.sh exited 0"; else record_fail "4.5 session B's run.sh exited $RC2B"; fi

ingest_results_file "$WS2A/results.txt" "concurrent-A"
ingest_results_file "$WS2B/results.txt" "concurrent-B"

if wait_for_absence_claude_gh 20; then
  record_pass "4.5 teardown: no claude-gh-* containers or networks remain after both sessions exit"
else
  record_fail "4.5 teardown: harness-created claude-gh-* leftovers remain (baseline/live-session resources excluded): [$(new_claude_gh_leftovers)]"
fi

# ===========================================================================
# Phase 3 (task 4.6): --gh-direct, no-token silence, flag conflict, bad image.
# Run only after phase 1/2 have fully torn down, so "no claude-gh-* resources"
# checks below aren't confused by an unrelated leftover from an earlier phase.
# ===========================================================================
echo
echo "=== Phase 3: --gh-direct / no-token / conflicting flags / bad sidecar image (4.6) ==="

# 4.6.a: --gh-direct forwards the real (fake) token, no sidecar at all.
WS3D="$SCRATCH/ghtest-direct"
mkdir -p "$WS3D"
gen_assert_script "$WS3D/assert.sh" direct "$FAKE_DIRECT" ""
LOG3D="$SCRATCH/run3d.log"
run_wrapped "$LOG3D" env \
  GH_TOKEN="$FAKE_DIRECT" \
  CLAUDE_DOCKER_RUNTIME=docker \
  CLAUDE_DOCKER_IMAGE="$TARGET_IMAGE" \
  CLAUDE_DOCKER_TEST_ENTRY="exec bash /workspaces/ghtest-direct/assert.sh" \
  bash "$RUN_SH" --gh-direct "$WS3D" &
PID3D=$!
BG_PIDS+=("$PID3D")
wait "$PID3D"
RC3D=$?
if [ "$RC3D" -eq 0 ]; then record_pass "4.6 --gh-direct session exited 0"; else record_fail "4.6 --gh-direct session exited $RC3D"; fi
ingest_results_file "$WS3D/results.txt" "gh-direct"
if no_new_claude_gh_resources; then
  record_pass "4.6 --gh-direct started no claude-gh-* sidecar or network"
else
  record_fail "4.6 --gh-direct unexpectedly left claude-gh-* resources behind"
fi

# 4.6.b: --gh with no discoverable host token — silent, no sidecar.
WS3N="$SCRATCH/ghtest-notoken"
mkdir -p "$WS3N"
gen_assert_script "$WS3N/assert.sh" notoken "" ""
LOG3N="$SCRATCH/run3n.log"
SAFE_PATH=$(make_no_gh_path)
run_wrapped "$LOG3N" env -u GH_TOKEN -u GITHUB_TOKEN PATH="$SAFE_PATH" \
  CLAUDE_DOCKER_RUNTIME=docker \
  CLAUDE_DOCKER_IMAGE="$TARGET_IMAGE" \
  CLAUDE_DOCKER_TEST_ENTRY="exec bash /workspaces/ghtest-notoken/assert.sh" \
  bash "$RUN_SH" --gh "$WS3N" &
PID3N=$!
BG_PIDS+=("$PID3N")
wait "$PID3N"
RC3N=$?
if [ "$RC3N" -eq 0 ]; then
  record_pass "4.6 --gh with no host token exits 0 (silent fallback)"
else
  record_fail "4.6 --gh with no host token exited $RC3N"
fi
# Heuristic, not a strict silence check: "error" is specific enough in
# practice (unlike e.g. "gh", which false-positives on ordinary English words)
# to flag a regression that starts printing warnings on this path.
if grep -qi 'error' "$LOG3N"; then
  record_fail "4.6 --gh with no host token printed something matching /error/i (expected silence): $(grep -i error "$LOG3N" | head -3 | tr '\n' ' ')"
else
  record_pass "4.6 --gh with no host token printed no error-like output"
fi
ingest_results_file "$WS3N/results.txt" "gh-no-token"
if no_new_claude_gh_resources; then
  record_pass "4.6 --gh with no host token started no sidecar or network"
else
  record_fail "4.6 --gh with no host token unexpectedly left claude-gh-* resources behind"
fi

# 4.6.c: --gh and --gh-direct together are rejected before anything starts.
WS3X="$SCRATCH/ghtest-conflict"
mkdir -p "$WS3X"
LOG3X="$SCRATCH/run3x.log"
run_wrapped "$LOG3X" env GH_TOKEN="$FAKE1" CLAUDE_DOCKER_RUNTIME=docker CLAUDE_DOCKER_IMAGE="$TARGET_IMAGE" \
  bash "$RUN_SH" --gh --gh-direct "$WS3X" &
PID3X=$!
BG_PIDS+=("$PID3X")
wait "$PID3X"
RC3X=$?
if [ "$RC3X" -ne 0 ]; then
  record_pass "4.6 --gh --gh-direct together exits non-zero ($RC3X)"
else
  record_fail "4.6 --gh --gh-direct together exited 0 (expected rejection)"
fi
if grep -qF -- '--gh' "$LOG3X" && grep -qF -- 'gh-direct' "$LOG3X"; then
  record_pass "4.6 --gh --gh-direct rejection message names the conflicting flags"
else
  record_fail "4.6 --gh --gh-direct rejection message doesn't clearly name both flags (see $LOG3X)"
fi
if no_new_claude_gh_resources; then
  record_pass "4.6 --gh --gh-direct started no container or sidecar"
else
  record_fail "4.6 --gh --gh-direct unexpectedly left claude-gh-* resources behind"
fi

# 4.6.d: sidecar start failure (unresolvable pinned image) fails closed.
WS3I="$SCRATCH/ghtest-badimage"
mkdir -p "$WS3I"
gen_assert_script "$WS3I/assert.sh" badimage-sentinel "$FAKE1" ""
LOG3I="$SCRATCH/run3i.log"
run_wrapped "$LOG3I" env \
  GH_TOKEN="$FAKE1" \
  CLAUDE_DOCKER_RUNTIME=docker \
  CLAUDE_DOCKER_IMAGE="$TARGET_IMAGE" \
  CLAUDE_DOCKER_PROXY_IMAGE="localhost/does-not-exist:0" \
  CLAUDE_DOCKER_TEST_ENTRY="exec bash /workspaces/ghtest-badimage/assert.sh" \
  bash "$RUN_SH" --gh "$WS3I" &
PID3I=$!
BG_PIDS+=("$PID3I")
wait "$PID3I"
RC3I=$?
if [ "$RC3I" -ne 0 ]; then
  record_pass "4.6 sidecar start failure (bad image) exits non-zero ($RC3I)"
else
  record_fail "4.6 sidecar start failure (bad image) exited 0 (expected fatal error)"
fi
# Absence of the sentinel is the pass condition: the assert script must NEVER
# run in this scenario, so results.txt is deliberately not ingested here.
if [ -f "$WS3I/should-not-exist" ]; then
  record_fail "4.6 agent container started and ran despite the sidecar failing to start — fail-closed regression (a real token could have been forwarded)"
else
  record_pass "4.6 agent container never started when the sidecar failed to start (fail-closed)"
fi
if no_new_claude_gh_resources; then
  record_pass "4.6 sidecar start failure left no claude-gh-* resources behind"
else
  record_fail "4.6 sidecar start failure left claude-gh-* resources behind"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=== gh-proxy-integration summary ==="
echo "PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL SKIP=$TOTAL_SKIP"
if [ "$TOTAL_FAIL" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
exit 0
