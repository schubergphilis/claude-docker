#!/usr/bin/env bats
# Unit tests for entrypoint.sh; every privileged command is stubbed.

setup() {
  # shellcheck source=../../entrypoint.sh
  source "${BATS_TEST_DIRNAME}/../../entrypoint.sh"
  SEED_SETTINGS="$BATS_TEST_TMPDIR/seed.json"
  ROOT_HOME="$BATS_TEST_TMPDIR/root"
  CA_DIR="$BATS_TEST_TMPDIR/ca"
  mkdir -p "$ROOT_HOME" "$CA_DIR"
  unset HOST_UID HOST_GID
  # Each stub echoes its call so tests can assert on what ran.
  chown() { echo "chown $*"; }
  groupadd() { echo "groupadd $*"; }
  useradd() { echo "useradd $*"; }
  # Its output is discarded by install_cas, so it logs to a file.
  update-ca-certificates() { echo ran >> "$BATS_TEST_TMPDIR/ca.log"; }
  find() { :; }
  xargs() { :; }
  # Entries getent knows about, e.g. "passwd claude" or "group 1000".
  KNOWN=""
  getent() { [[ " $KNOWN " == *" $1 $2 "* ]]; }
  # UID `id -u claude` reports for a pre-existing claude user.
  CLAUDE_UID=1000
  id() { echo "$CLAUDE_UID"; }
  # exec bypasses shell functions, so runuser is a PATH stub.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\necho "runuser $*"\n' > "$BATS_TEST_TMPDIR/bin/runuser"
  chmod +x "$BATS_TEST_TMPDIR/bin/runuser"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "HOST_UID unset execs the command as root" {
  run main echo hello
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "HOST_UID=0 execs the command without creating a user" {
  HOST_UID=0 run main echo hello
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "non-root HOST_UID creates claude and drops via runuser" {
  HOST_UID=1000 HOST_GID=1000 run main claude --flag
  [ "$status" -eq 0 ]
  [[ "$output" == *"groupadd -o -g 1000 claude"* ]]
  [[ "$output" == *"useradd -o -K UID_MIN=1 -u 1000 -g 1000 -d /root -s /bin/bash -M -N claude"* ]]
  [[ "$output" == *"runuser -u claude -- claude --flag"* ]]
}

@test "existing GID is reused, no groupadd" {
  KNOWN="group 20"
  run ensure_user 501 20
  [ "$status" -eq 0 ]
  [[ "$output" != *groupadd* ]]
  [[ "$output" == *"useradd -o -K UID_MIN=1 -u 501 -g 20"* ]]
}

@test "HOST_UID colliding with an image user still creates claude" {
  KNOWN="passwd 1000 group 1000"
  run ensure_user 1000 1000
  [ "$status" -eq 0 ]
  [[ "$output" == *"useradd -o -K UID_MIN=1 -u 1000 -g 1000"* ]]
}

@test "existing claude user with HOST_UID is left alone" {
  KNOWN="passwd claude"
  run ensure_user 1000 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "existing claude user with another UID is refused" {
  KNOWN="passwd claude"
  CLAUDE_UID=0
  run ensure_user 1000 1000
  [ "$status" -ne 0 ]
  [ "$output" = "entrypoint: ERROR existing claude user has UID 0, expected HOST_UID 1000" ]
}

@test "existing claude user with another UID stops main before runuser" {
  KNOWN="passwd claude"
  CLAUDE_UID=1001
  HOST_UID=1000 HOST_GID=1000 run main claude
  [ "$status" -ne 0 ]
  [[ "$output" == *"existing claude user has UID 1001, expected HOST_UID 1000"* ]]
  [[ "$output" != *runuser* ]]
}

@test "EROFS chown errors are filtered out" {
  xargs() { echo "chown: changing ownership of '/root/.aws/config': Read-only file system" >&2; return 1; }
  run chown_volumes 1000 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "other chown errors are reported as WARN" {
  xargs() {
    echo "chown: changing ownership of '/root/.aws/config': Read-only file system" >&2
    echo "chown: changing ownership of '/root/x': Operation not permitted" >&2
    return 1
  }
  run chown_volumes 1000 1000
  [ "$status" -eq 0 ]
  [ "$output" = "entrypoint: WARN chown: chown: changing ownership of '/root/x': Operation not permitted" ]
}

@test "find errors are reported as WARN" {
  find() { echo "find: '/root/y': Permission denied" >&2; return 1; }
  run chown_volumes 1000 1000
  [ "$status" -eq 0 ]
  [ "$output" = "entrypoint: WARN chown: find: '/root/y': Permission denied" ]
}

@test "chown walk skips a missing /root/.claude" {
  find() { printf '%s\n' "$@" >"$BATS_TEST_TMPDIR/find.args"; }
  chown_volumes 1000 1000
  [ "$(head -2 "$BATS_TEST_TMPDIR/find.args")" = "$ROOT_HOME"$'\n'"-xdev" ]
  mkdir "$ROOT_HOME/.claude"
  chown_volumes 1000 1000
  [ "$(head -2 "$BATS_TEST_TMPDIR/find.args")" = "$ROOT_HOME"$'\n'"$ROOT_HOME/.claude" ]
}

@test "chown walk runs under LC_ALL=C" {
  xargs() { echo "LC_ALL=${LC_ALL-}" >&2; }
  HOST_UID=1000 HOST_GID=1000 run main true
  [[ "$output" == *"entrypoint: WARN chown: LC_ALL=C"* ]]
}

@test "no claude-docker CA skips update-ca-certificates" {
  run install_cas
  [ "$status" -eq 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/ca.log" ]
}

@test "claude-docker CA present runs update-ca-certificates" {
  touch "$CA_DIR/claude-docker-gh.crt"
  run install_cas
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$(cat "$BATS_TEST_TMPDIR/ca.log")" = ran ]
}

@test "CA refresh failure warns and the entrypoint continues" {
  touch "$CA_DIR/claude-docker-gh.crt"
  update-ca-certificates() { return 1; }
  HOST_UID=0 run main echo hello
  [ "$status" -eq 0 ]
  [[ "$output" == *"entrypoint: WARN update-ca-certificates failed"* ]]
  [[ "$output" == *"hello"* ]]
}

@test "settings seed replaces settings.json with mode 600" {
  echo '{"a":1}' > "$SEED_SETTINGS"
  mkdir -p "$ROOT_HOME/.claude"
  echo stale > "$ROOT_HOME/.claude/settings.json"
  run seed_settings
  [ "$status" -eq 0 ]
  [ "$output" = "chown root $ROOT_HOME/.claude" ]
  [ "$(cat "$ROOT_HOME/.claude/settings.json")" = '{"a":1}' ]
  [ "$(stat -c %a "$ROOT_HOME/.claude/settings.json")" = 600 ]
}

@test "absent settings seed touches nothing" {
  run seed_settings
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ROOT_HOME/.claude" ]
}

@test "failed settings seed aborts before the exec" {
  echo '{}' > "$SEED_SETTINGS"
  chown() { return 7; }
  run main echo hello
  [ "$status" -eq 7 ]
  [[ "$output" != *hello* ]]
}

@test "failed groupadd aborts before useradd and runuser" {
  groupadd() { return 9; }
  HOST_UID=1000 HOST_GID=1000 run main claude
  [ "$status" -eq 9 ]
  [[ "$output" != *useradd* ]]
  [[ "$output" != *runuser* ]]
}

@test "failed useradd aborts before runuser" {
  useradd() { return 9; }
  HOST_UID=1000 HOST_GID=1000 run main claude
  [ "$status" -eq 9 ]
  [[ "$output" != *runuser* ]]
}

# --- approve_api_key (--egress-lock) ---------------------------------------

API_KEY="sk-ant-test-0123456789abcdefghijKLMNOPQRSTUV"
API_KEY_ID="${API_KEY: -20}"

# Runs approve_api_key with the lock on and $1 (default $API_KEY) as the key.
approve() {
  CLAUDE_DOCKER_EGRESS_LOCK=1 ANTHROPIC_API_KEY="${1-$API_KEY}" run approve_api_key
}

@test "approve_api_key: a fresh volume gets the key approved, owner-only" {
  approve
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$ROOT_HOME/.claude.json")" = "{\"customApiKeyResponses\":{\"rejected\":[],\"approved\":[\"$API_KEY_ID\"]}}" ]
  [ "$(stat -c %a "$ROOT_HOME/.claude.json")" = 600 ]
  [ "$(ls -A "$ROOT_HOME")" = .claude.json ]
}

@test "approve_api_key: an existing config is kept and the key not duplicated" {
  printf '%s' '{"hasCompletedOnboarding":true,"customApiKeyResponses":{"approved":["other"],"rejected":["x"]}}' \
    > "$ROOT_HOME/.claude.json"
  approve
  approve
  [ "$status" -eq 0 ]
  [ "$(jq -c . "$ROOT_HOME/.claude.json")" = "{\"hasCompletedOnboarding\":true,\"customApiKeyResponses\":{\"approved\":[\"other\",\"$API_KEY_ID\"],\"rejected\":[\"x\"]}}" ]
  [ "$(ls -A "$ROOT_HOME")" = .claude.json ]
}

@test "approve_api_key: the key is trimmed, as Claude Code does" {
  approve "  $API_KEY"$'\n'
  [ "$(jq -c .customApiKeyResponses.approved "$ROOT_HOME/.claude.json")" = "[\"$API_KEY_ID\"]" ]
}

@test "approve_api_key: a key shorter than 20 characters is approved whole" {
  # Under --api the agent sees the sidecar's 19-character placeholder.
  approve claude-docker-proxy
  [ "$(jq -c .customApiKeyResponses.approved "$ROOT_HOME/.claude.json")" = '["claude-docker-proxy"]' ]
}

@test "approve_api_key: no lock or no key touches nothing" {
  CLAUDE_DOCKER_EGRESS_LOCK="" ANTHROPIC_API_KEY="$API_KEY" run approve_api_key
  [ "$status" -eq 0 ]
  approve ""
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$ROOT_HOME/.claude.json" ]
}

@test "approve_api_key: invalid JSON is left alone with a WARN" {
  printf '{not json' > "$ROOT_HOME/.claude.json"
  approve
  [ "$status" -eq 0 ]
  [[ "$output" == *"$ROOT_HOME/.claude.json is not valid JSON; not approving ANTHROPIC_API_KEY"* ]]
  [ "$(cat "$ROOT_HOME/.claude.json")" = '{not json' ]
  [ "$(ls -A "$ROOT_HOME")" = .claude.json ]
}

@test "approve_api_key: a symlinked .claude.json is not followed" {
  local other="$BATS_TEST_TMPDIR/other" dest
  mkdir -p "$other"
  printf '{"secret":1}' > "$other/secret.json"
  for dest in "$other/secret.json" "$other/missing.json"; do
    rm -f "$ROOT_HOME/.claude.json"
    ln -s "$dest" "$ROOT_HOME/.claude.json"
    approve
    [ "$status" -eq 0 ]
    [[ "$output" == *"$ROOT_HOME/.claude.json is not a regular file; not approving ANTHROPIC_API_KEY"* ]]
    [ -L "$ROOT_HOME/.claude.json" ]
  done
  [ "$(cat "$other/secret.json")" = '{"secret":1}' ]
  [ ! -e "$other/missing.json" ]
  [ "$(ls -A "$ROOT_HOME")" = .claude.json ]
}

@test "approve_api_key: chowns ROOT_HOME back to root before writing" {
  approve
  [[ "$output" == *"chown root $ROOT_HOME"* ]]
}

@test "approve_api_key: a failed chown stops before writing" {
  chown() { return 7; }
  approve
  [ "$status" -eq 7 ]
  [ ! -e "$ROOT_HOME/.claude.json" ]
}

@test "approve_api_key: a failed rename leaves no temp file in the volume" {
  printf '{}' > "$ROOT_HOME/.claude.json"
  mv() { return 5; }
  approve
  [ "$status" -eq 5 ]
  [ "$(cat "$ROOT_HOME/.claude.json")" = '{}' ]
  [ "$(ls -A "$ROOT_HOME")" = .claude.json ]
}

@test "approve_api_key: a failed mktemp stops before writing" {
  mktemp() { return 6; }
  approve
  [ "$status" -eq 6 ]
  [ -z "$(ls -A "$ROOT_HOME")" ]
}
