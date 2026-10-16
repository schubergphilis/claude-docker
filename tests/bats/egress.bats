#!/usr/bin/env bats
# Unit tests for tests/smoke/egress.sh; run.sh, docker and script are stubbed,
# so no daemon is needed. The real cells run in ci.yml's docker-build job.
# Globals set here are read by the sourced egress.sh functions (SC2034).
# shellcheck disable=SC2034

setup() {
  unset IMAGE
  export HOME="${BATS_TEST_TMPDIR}/home"
  mkdir -p "$HOME"
  # shellcheck source=../smoke/egress.sh
  source "${BATS_TEST_DIRNAME}/../smoke/egress.sh"
  # Leftover lists the stub reports; empty = none.
  STUB_PS="" STUB_NETWORKS="" STUB_SQUID=""
  docker() {
    case "$1" in
      ps) printf '%s' "$STUB_PS" ;;
      network) printf '%s' "$STUB_NETWORKS" ;;
      run) [ -n "$STUB_SQUID" ] ;;
    esac
  }
}

# Parse args and build the workspace, with a fake run.sh that refuses every
# startup with the message the endpoint calls for.
setup_cell() {
  parse_args "$@"
  # Keep bats' own EXIT trap: the temp dir sits under BATS_TEST_TMPDIR anyway.
  trap() { :; }
  setup_workspace
  unset -f trap
  RUN_SH="${BATS_TEST_TMPDIR}/fake-run.sh"
  cat > "$RUN_SH" <<'SH'
#!/usr/bin/env bash
case "${ANTHROPIC_BASE_URL:-}" in
  "") echo "claude-docker: --egress-lock needs ANTHROPIC_BASE_URL" >&2 ;;
  *anthropic.com) echo "claude-docker: ... and ANTHROPIC_BASE_URL points at one" >&2 ;;
  *$'\n'*) echo "claude-docker: ANTHROPIC_BASE_URL host is not a valid hostname" >&2 ;;
  *) exit 0 ;;
esac
exit 1
SH
  chmod +x "$RUN_SH"
}

# A session transcript and saved log/meta, as a passing session leaves them.
fake_session() {
  local dir="$TMPROOT/state/claude-docker/egress"
  mkdir -p "$dir"
  transcript="$TMPROOT/transcript.txt"
  endpoint_host="${1:-example.com}"
  cat > "$transcript" <<TXT
claude-docker: egress proxy 'claude-egress-proxy-a1B2c3' is active
RESULT: PASS
claude-docker: egress proxy blocked: api.anthropic.com example.org:22 
TXT
  printf '%s\n' "1 0 1 TCP_TUNNEL/200 0 CONNECT example.org:443 - HIER_DIRECT/x -" \
    "1 0 1 TCP_TUNNEL/200 0 CONNECT github.com:22 - HIER_DIRECT/x -" > "$dir/s.log"
  printf '%s\n' "endpoint=$endpoint_host" "proxy_image=claude-docker-egress-proxy:abc" > "$dir/s.meta"
}

# --- argument parsing ------------------------------------------------------

@test "defaults: plain cell, IMAGE or the local tag" {
  parse_args
  [ "$WITH_GH" = 0 ] && [ -z "$ENDPOINT_PORT" ] && [ "$IMAGE" = claude-code:local ]
  IMAGE=img:tag
  parse_args --gh --endpoint-port
  [ "$WITH_GH" = 1 ] && [ "$ENDPOINT_PORT" = 22 ] && [ "$IMAGE" = img:tag ]
}

@test "unknown argument is rejected" {
  run parse_args --nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"unknown argument '--nope'"* ]]
}

# --- workspace -------------------------------------------------------------

@test "setup_workspace stages the assert script under HOME" {
  setup_cell
  [[ "$TMPROOT" == "$HOME/.cache/claude-docker/egress-smoke."* ]]
  [ -x "$WS/assert-in-container.sh" ]
  [[ " ${api_env[*]} " == *" XDG_STATE_HOME=$TMPROOT/state "* ]]
}

@test "cleanup removes the scratch dir" {
  setup_cell
  cleanup
  [ ! -e "$TMPROOT" ]
}

# --- refused endpoints -----------------------------------------------------

@test "every refused endpoint passes against run.sh's messages" {
  setup_cell
  run check_refused_endpoints
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: missing, provider and injected endpoints abort startup"* ]]
}

@test "an endpoint run.sh accepts fails the cell" {
  setup_cell
  run refused "https://example.com" "anything"
  [ "$status" -eq 1 ]
  [[ "$output" == *"run.sh started an --egress-lock session with ANTHROPIC_BASE_URL='https://example.com'"* ]]
}

@test "a refusal with the wrong message fails the cell" {
  setup_cell
  run refused "" "points at one"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rejected without 'points at one'"* ]]
}

# --- session ---------------------------------------------------------------

@test "run_session passes the endpoint and expectations to run.sh" {
  setup_cell --gh --endpoint-port
  # script runs the quoted command line; record it and play a passing session.
  script() { printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/cmd"; echo "RESULT: PASS" > "$3"; echo 0 > "$TMPROOT/rc"; }
  timeout() { shift 3; "$@"; }
  run_session >/dev/null
  [ "$endpoint_host" = github.com ] && [ "$endpoint_url" = https://github.com:22 ]
  # The endpoint-port cell needs the agent to dial the endpoint: --api-direct.
  [ "${flags[*]}" = "--api-direct --egress-lock --ephemeral --gh" ]
  grep -q 'ANTHROPIC_BASE_URL=https://github.com:22' "$BATS_TEST_TMPDIR/cmd"
  grep -q 'GH_TOKEN=ghp_fake' "$BATS_TEST_TMPDIR/cmd"
  grep -q 'EXPECT_EGRESS_GH=1' "$BATS_TEST_TMPDIR/cmd"
  grep -q 'EXPECT_EGRESS_MANAGED_URL=https://github.com:22' "$BATS_TEST_TMPDIR/cmd"
}

@test "run_session: the plain cell goes through the --api auth-proxy sidecar" {
  setup_cell
  script() { printf '%s\n' "$2" > "$BATS_TEST_TMPDIR/cmd"; echo "RESULT: PASS" > "$3"; echo 0 > "$TMPROOT/rc"; }
  timeout() { shift 3; "$@"; }
  run_session >/dev/null
  [ "${flags[*]}" = "--api --egress-lock --ephemeral" ] && [ "$API_PROXY" = 1 ]
  grep -q 'EXPECT_EGRESS_API_PROXY=1' "$BATS_TEST_TMPDIR/cmd"
  grep -q 'EXPECT_EGRESS_MANAGED_URL=http://claude-docker-api-proxy:8080' "$BATS_TEST_TMPDIR/cmd"
  grep -q 'ANTHROPIC_BASE_URL=https://example.com' "$BATS_TEST_TMPDIR/cmd"
}

@test "run_session fails on a non-zero exit or a missing PASS" {
  setup_cell
  timeout() { shift 3; "$@"; }
  script() { : > "$3"; echo 3 > "$TMPROOT/rc"; }
  run run_session
  [ "$status" -eq 1 ]
  [[ "$output" == *"run.sh session exited 3"* ]]
  script() { echo "RESULT: FAIL" > "$3"; echo 0 > "$TMPROOT/rc"; }
  run run_session
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not report PASS"* ]]
}

# --- host-side evidence ----------------------------------------------------

@test "assert_evidence passes on a complete session" {
  setup_cell
  fake_session
  run assert_evidence
  [ "$status" -eq 0 ]
  [[ "$output" == *"PASS: startup banner, denied summary, saved log"* ]]
}

@test "assert_evidence checks the endpoint port's allow and deny" {
  setup_cell --endpoint-port
  fake_session github.com
  run assert_evidence
  [ "$status" -eq 0 ]
  sed -i 's/ example.org:22 / /' "$transcript"
  run assert_evidence
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not list example.org:22"* ]]
}

@test "assert_evidence under --api needs the request to the auth-proxy sidecar" {
  setup_cell
  fake_session
  API_PROXY=1
  run assert_evidence
  [ "$status" -eq 1 ]
  [[ "$output" == *"lacks the agent's request to the --api auth-proxy sidecar"* ]]
  echo "1 0 1 TCP_MISS/404 0 GET http://claude-docker-api-proxy:8080/ - HIER_DIRECT/x -" \
    >> "$TMPROOT/state/claude-docker/egress/s.log"
  run assert_evidence
  [ "$status" -eq 0 ]
}

@test "assert_evidence fails without the saved meta" {
  setup_cell
  fake_session
  rm "$TMPROOT/state/claude-docker/egress/s.meta"
  run assert_evidence
  [ "$status" -eq 1 ]
  [[ "$output" == *"no egress log/meta saved"* ]]
}

@test "assert_evidence fails when the agent image has squid" {
  setup_cell
  fake_session
  STUB_SQUID=1
  run assert_evidence
  [ "$status" -eq 1 ]
  [[ "$output" == *"the agent image still contains squid"* ]]
}

# --- teardown --------------------------------------------------------------

@test "assert_teardown passes with nothing left" {
  setup_cell
  fake_session
  run assert_teardown
  [ "$status" -eq 0 ]
  [[ "$output" == *"no resources of session a1B2c3 left"* ]]
}

@test "assert_teardown names this session's leftovers" {
  setup_cell
  fake_session
  STUB_PS="cid" STUB_NETWORKS="nid"
  run assert_teardown
  [ "$status" -eq 1 ]
  [[ "$output" == *"claude-egress-proxy-a1B2c3 claude-auth-proxy-a1B2c3 network:claude-egress-a1B2c3"* ]]
}

@test "assert_teardown fails without a session id" {
  setup_cell
  transcript="$TMPROOT/transcript.txt"
  : > "$transcript"
  run assert_teardown
  [ "$status" -eq 1 ]
  [[ "$output" == *"no session id in the startup banner"* ]]
}
