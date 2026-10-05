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

@test "existing claude user is left alone" {
  KNOWN="passwd claude"
  run ensure_user 1000 1000
  [ "$status" -eq 0 ]
  [ -z "$output" ]
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
