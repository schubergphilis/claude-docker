#!/usr/bin/env bats
# Unit tests for smoke/assert-in-container.sh; /proc, /root and the CA paths
# point at fixtures under $BATS_TEST_TMPDIR.

setup() {
  # shellcheck source=../../smoke/assert-in-container.sh
  source "${BATS_TEST_DIRNAME}/../../smoke/assert-in-container.sh"
  ROOT_HOME="${BATS_TEST_TMPDIR}/root"
  PROC_STATUS="${BATS_TEST_TMPDIR}/status"
  PROC_MOUNTS="${BATS_TEST_TMPDIR}/mounts"
  API_CA="${BATS_TEST_TMPDIR}/api.crt"
  CA_BUNDLE="${BATS_TEST_TMPDIR}/bundle.crt"
  mkdir -p "$ROOT_HOME"
  unset EXPECT_OPTINS AWS_PROFILE GITLAB_TOKEN TF_TOKEN_app_terraform_io \
    AZURE_DEVOPS_EXT_PAT ANTHROPIC_BASE_URL EXPECT_SETTINGS EXPECT_SETTINGS_SENTINEL
  # A writable fixture can't produce EROFS; that check needs a real :ro mount.
  assert_write_fails_ro() { pass "$1: stubbed"; }
}

# --- pass / fail / assert_eq -------------------------------------------------

@test "pass and fail bump their counters" {
  pass a >/dev/null
  pass b >/dev/null
  fail c >/dev/null
  [ "$PASS_COUNT" -eq 2 ]
  [ "$FAIL_COUNT" -eq 1 ]
}

@test "assert_eq passes on equal values" {
  assert_eq lbl x x >/dev/null
  [ "$PASS_COUNT" -eq 1 ] && [ "$FAIL_COUNT" -eq 0 ]
  run assert_eq lbl x x
  [ "$output" = "PASS: lbl: got 'x'" ]
}

@test "assert_eq fails on different values" {
  assert_eq lbl x y >/dev/null
  [ "$PASS_COUNT" -eq 0 ] && [ "$FAIL_COUNT" -eq 1 ]
  run assert_eq lbl x y
  [ "$output" = "FAIL: lbl: expected 'y', got 'x'" ]
}

# --- path_index / assert_path_before -----------------------------------------

@test "path_index finds an entry" {
  PATH=/a:/b:/c run path_index /b
  [ "$output" = 1 ]
}

@test "path_index returns -1 when absent" {
  PATH=/a:/b run path_index /z
  [ "$output" = -1 ]
}

@test "path_index does not match a prefix" {
  PATH=/root/go/bin/foo:/usr/bin run path_index /root/go/bin
  [ "$output" = -1 ]
}

@test "assert_path_before: first missing" {
  PATH=/b run assert_path_before /a /b
  [[ "$output" == "FAIL: path-order: /a is not on PATH"* ]]
}

@test "assert_path_before: second missing" {
  PATH=/a run assert_path_before /a /b
  [[ "$output" == "FAIL: path-order: /b is not on PATH"* ]]
}

@test "assert_path_before: correct order" {
  PATH=/a:/b run assert_path_before /a /b
  [ "$output" = "PASS: path-order: /a (#0) precedes /b (#1)" ]
}

@test "assert_path_before: wrong order" {
  PATH=/b:/a run assert_path_before /a /b
  [[ "$output" == "FAIL: path-order: expected /a before /b"* ]]
}

# --- optin_config_path -------------------------------------------------------

@test "optin_config_path maps every opt-in" {
  [ "$(optin_config_path aws)" = "${ROOT_HOME}/.aws/config:AWS_PROFILE" ]
  [ "$(optin_config_path glab)" = "${ROOT_HOME}/.config/glab-cli:GITLAB_TOKEN" ]
  [ "$(optin_config_path tfe)" = "${ROOT_HOME}/.terraform.d/credentials.tfrc.json:TF_TOKEN_app_terraform_io" ]
  [ "$(optin_config_path az)" = "${ROOT_HOME}/.azure:AZURE_DEVOPS_EXT_PAT" ]
}

@test "optin_config_path is empty for an unknown name" {
  [ -z "$(optin_config_path nope)" ]
}

# --- check_credentials -------------------------------------------------------

@test "check_credentials: nothing granted, nothing present" {
  run check_credentials
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PASS: masked-glab: config path absent"* ]]
  [[ "$output" == *"PASS: leak-glab: GITLAB_TOKEN not forwarded"* ]]
}

@test "check_credentials: granted opt-in with fixture and env passes" {
  mkdir -p "${ROOT_HOME}/.config/glab-cli"
  echo SMOKE-SENTINEL > "${ROOT_HOME}/.config/glab-cli/config.yml"
  EXPECT_OPTINS=glab,az GITLAB_TOKEN=t AZURE_DEVOPS_EXT_PAT=SMOKE-SENTINEL-pat \
    run check_credentials
  [[ "$output" != *FAIL* ]]
  [[ "$output" == *"PASS: optin-glab-content"* ]]
  [[ "$output" == *"PASS: optin-glab-env"* ]]
  [[ "$output" == *"PASS: optin-az-env"* ]]
}

@test "check_credentials: granted opt-in without fixture or env fails" {
  EXPECT_OPTINS=tfe run check_credentials
  [[ "$output" == *"FAIL: optin-tfe: config path missing"* ]]
  [[ "$output" == *"FAIL: optin-tfe-content"* ]]
  [[ "$output" == *"FAIL: optin-tfe-env"* ]]
}

@test "check_credentials: populated config without its opt-in fails" {
  mkdir -p "${ROOT_HOME}/.azure"
  touch "${ROOT_HOME}/.azure/x"
  run check_credentials
  [[ "$output" == *"FAIL: masked-az: config path unexpectedly populated"* ]]
}

@test "check_credentials: env var leaked without its opt-in fails" {
  GITLAB_TOKEN=leak run check_credentials
  [[ "$output" == *"FAIL: leak-glab: GITLAB_TOKEN is set"* ]]
  [[ "$output" == *"PASS: leak-tfe"* ]]
}

@test "check_credentials leaves IFS alone" {
  EXPECT_OPTINS=aws,glab check_credentials >/dev/null
  [ "$IFS" = $' \t\n' ]
}

# --- check_security ----------------------------------------------------------

status_fixture() {
  printf '%s\n' "CapPrm:	0000000000000000" "CapEff:	0000000000000000" \
    "CapBnd:	00000000000000c5" "NoNewPrivs:	1" "$@" > "$PROC_STATUS"
}

@test "check_security: dropped posture passes" {
  status_fixture "CapAmb:	0000000000000000"
  EXPECT_UID=1000 run check_security
  [[ "$output" != *"FAIL: Cap"* ]] && [[ "$output" != *"FAIL: NoNewPrivs"* ]]
  [[ "$output" == *"PASS: CapAmb=0"* ]]
  [[ "$output" == *"PASS: CapBnd+NoNewPrivs"* ]]
}

@test "check_security: a missing Cap field fails instead of aborting" {
  status_fixture
  EXPECT_UID=1000 run bash -c 'set -euo pipefail; source "$1"; PROC_STATUS=$2; check_security; echo done' _ \
    "${BATS_TEST_DIRNAME}/../../smoke/assert-in-container.sh" "$PROC_STATUS"
  [[ "$output" == *"FAIL: CapAmb=0: expected '0000000000000000', got ''"* ]]
  [[ "$output" == *done* ]]
}

# --- check_aws_state_masking -------------------------------------------------

@test "check_aws_state_masking: tmpfs mask matched by exact mountpoint" {
  mkdir -p "${ROOT_HOME}/.aws"
  echo "tmpfs ${ROOT_HOME}/.aws tmpfs rw 0 0" > "$PROC_MOUNTS"
  run check_aws_state_masking
  [[ "$output" == *"PASS: masked-aws-dir-mount"* ]]
}

@test "check_aws_state_masking: a mountpoint that only regex-matches fails" {
  mkdir -p "${ROOT_HOME}/.aws"
  # '.' in the path would match any char as an ERE.
  echo "tmpfs ${ROOT_HOME}/xaws tmpfs rw 0 0" > "$PROC_MOUNTS"
  run check_aws_state_masking
  [[ "$output" == *"FAIL: masked-aws-dir-mount"* ]]
}

# --- check_api ---------------------------------------------------------------

@test "check_api: CA present in the bundle passes" {
  printf '%s\n' "-----BEGIN CERTIFICATE-----" "MIIUNIQUE" > "$API_CA"
  printf '%s\n' other MIIUNIQUE > "$CA_BUNDLE"
  EXPECT_OPTINS=api ANTHROPIC_BASE_URL=https://x run check_api
  [[ "$output" == *"PASS: optin-api-ca"* ]]
}

@test "check_api: empty CA line 2 does not match any bundle" {
  printf '%s\n' "-----BEGIN CERTIFICATE-----" "" > "$API_CA"
  echo anything > "$CA_BUNDLE"
  EXPECT_OPTINS=api ANTHROPIC_BASE_URL=https://x run check_api
  [[ "$output" == *"FAIL: optin-api-ca"* ]]
}

@test "check_api: CA line starting with a dash is matched literally" {
  printf '%s\n' "-----BEGIN CERTIFICATE-----" "-v" > "$API_CA"
  echo "-v" > "$CA_BUNDLE"
  EXPECT_OPTINS=api ANTHROPIC_BASE_URL=https://x run check_api
  [[ "$output" == *"PASS: optin-api-ca"* ]]
}

# --- check_settings ----------------------------------------------------------

@test "check_settings: sentinel mismatch reports size, not content" {
  mkdir -p "${ROOT_HOME}/.claude"
  echo '{"token":"secret"}' > "${ROOT_HOME}/.claude/settings.json"
  EXPECT_SETTINGS=1 EXPECT_SETTINGS_SENTINEL=want run check_settings
  [[ "$output" == *"FAIL: settings-content"*"19 bytes"* ]]
  [[ "$output" != *secret* ]]
}

@test "check_settings: sentinel starting with a dash is matched literally" {
  mkdir -p "${ROOT_HOME}/.claude"
  echo '{"x":"-v"}' > "${ROOT_HOME}/.claude/settings.json"
  EXPECT_SETTINGS=1 EXPECT_SETTINGS_SENTINEL=-v run check_settings
  [[ "$output" == *"PASS: settings-content"* ]]
  [[ "$output" == *"PASS: settings-rename"* ]]
}
