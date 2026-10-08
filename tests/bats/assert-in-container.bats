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
  SEED_SETTINGS="${BATS_TEST_TMPDIR}/seed.json"
  mkdir -p "$ROOT_HOME"
  unset EXPECT_OPTINS EXPECT_EPHEMERAL AWS_PROFILE GITLAB_TOKEN TF_TOKEN_app_terraform_io \
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
  find() { :; }  # skip the setuid walk over the runner's whole filesystem
  EXPECT_UID=1000 run check_security
  [[ "$output" != *"FAIL: Cap"* ]] && [[ "$output" != *"FAIL: NoNewPrivs"* ]]
  [[ "$output" == *"PASS: CapAmb=0"* ]]
  [[ "$output" == *"PASS: CapBnd+NoNewPrivs"* ]]
}

@test "check_security: a missing Cap field fails instead of aborting" {
  status_fixture
  EXPECT_UID=1000 run bash -c 'set -euo pipefail; source "$1"; PROC_STATUS=$2; find() { :; }; check_security; echo done' _ \
    "${BATS_TEST_DIRNAME}/../../smoke/assert-in-container.sh" "$PROC_STATUS"
  [[ "$output" == *"FAIL: CapAmb=0: expected '0000000000000000', got ''"* ]]
  [[ "$output" == *done* ]]
}

# --- check_mask_set ----------------------------------------------------------

# One tmpfs line per mountpoint, plus a non-tmpfs mount under /root to ignore.
write_mounts() {
  : > "$PROC_MOUNTS"
  local m
  for m in "$@"; do echo "tmpfs $m tmpfs rw 0 0" >> "$PROC_MOUNTS"; done
  echo "/dev/vda1 /root/.claude ext4 rw 0 0" >> "$PROC_MOUNTS"
}

@test "check_mask_set: no opt-ins expects every mask" {
  write_mounts /root/.config/gh /root/.config/glab-cli /root/.terraform.d /root/.azure /root/.aws
  run check_mask_set
  [[ "$output" == "PASS: mask-set:"* ]]
}

@test "check_mask_set: aws narrows its mask to the cli cache" {
  export EXPECT_OPTINS=aws,glab
  write_mounts /root/.config/gh /root/.terraform.d /root/.azure /root/.aws/cli/cache
  run check_mask_set
  [[ "$output" == "PASS: mask-set:"* ]]
}

@test "check_mask_set: a dropped mask fails" {
  write_mounts /root/.config/gh /root/.terraform.d /root/.azure /root/.aws
  run check_mask_set
  [[ "$output" == "FAIL: mask-set:"* ]]
}

@test "check_mask_set: an extra mask fails" {
  export EXPECT_EPHEMERAL=1
  write_mounts /root/.aws
  run check_mask_set
  [[ "$output" == "FAIL: mask-set:"* ]]
}

@test "check_mask_set: a mountpoint that only regex-matches is not a mask" {
  EXPECT_EPHEMERAL=1
  # '.' would match any char as an ERE.
  write_mounts /rootxaws
  run check_mask_set
  [[ "$output" == "PASS: mask-set:"* ]]
}

# --- check_aws_state_masking -------------------------------------------------

@test "check_aws_state_masking: ephemeral with no cache passes" {
  EXPECT_EPHEMERAL=1 run check_aws_state_masking
  [[ "$output" == "PASS: ephemeral-aws:"* ]]
}

@test "check_aws_state_masking: ephemeral with a populated cache fails" {
  mkdir -p "${ROOT_HOME}/.aws/cli/cache"
  touch "${ROOT_HOME}/.aws/cli/cache/sts.json"
  EXPECT_EPHEMERAL=1 run check_aws_state_masking
  [[ "$output" == "FAIL: ephemeral-aws:"* ]]
}

@test "check_aws_state_masking: not granted, empty .aws mask passes" {
  mkdir -p "${ROOT_HOME}/.aws"
  run check_aws_state_masking
  [[ "$output" == "PASS: masked-aws-dir:"* ]]
  [[ "$output" != *FAIL* ]]
}

@test "check_aws_state_masking: not granted, populated .aws fails" {
  mkdir -p "${ROOT_HOME}/.aws"
  touch "${ROOT_HOME}/.aws/credentials"
  run check_aws_state_masking
  [[ "$output" == "FAIL: masked-aws-dir: ${ROOT_HOME}/.aws unexpectedly populated (1 entries)" ]]
}

@test "check_aws_state_masking: a missing mask path fails" {
  run check_aws_state_masking
  [[ "$output" == "FAIL: masked-aws-dir: ${ROOT_HOME}/.aws does not exist"* ]]
}

@test "check_aws_state_masking: --aws with an empty, writable cache and config passes" {
  mkdir -p "${ROOT_HOME}/.aws/cli/cache"
  touch "${ROOT_HOME}/.aws/config"
  EXPECT_OPTINS=aws run check_aws_state_masking
  [[ "$output" == *"PASS: aws-cache-masked:"* ]]
  [[ "$output" == *"PASS: aws-cache-masked-scope:"* ]]
  [[ "$output" == *"PASS: aws-cache-writable:"* ]]
  [[ "$output" != *FAIL* ]]
  [ ! -e "${ROOT_HOME}/.aws/cli/cache/__smoke_write_test" ]
}

@test "check_aws_state_masking: --aws with the config hidden fails the scope check" {
  mkdir -p "${ROOT_HOME}/.aws/cli/cache"
  EXPECT_OPTINS=aws run check_aws_state_masking
  [[ "$output" == *"FAIL: aws-cache-masked-scope:"* ]]
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

@test "check_settings: no seed on fresh volumes passes when nothing was seeded" {
  EXPECT_SETTINGS=0 run check_settings
  [ "$output" = "PASS: settings-absent: no settings file without a seed" ]
}

@test "check_settings: no seed but a settings file fails" {
  mkdir -p "${ROOT_HOME}/.claude"
  echo '{}' > "${ROOT_HOME}/.claude/settings.json"
  EXPECT_SETTINGS=0 run check_settings
  [[ "$output" == "FAIL: settings-absent:"* ]]
}

@test "check_settings: keep passes on a persisted file with no seed" {
  mkdir -p "${ROOT_HOME}/.claude"
  echo '{"env":{"S":"V2"}}' > "${ROOT_HOME}/.claude/settings.json"
  EXPECT_SETTINGS=keep EXPECT_SETTINGS_SENTINEL=V2 run check_settings
  [[ "$output" == *"PASS: settings-keep: no seed mounted this run"* ]]
  [[ "$output" == *"PASS: settings-content:"* ]]
  [[ "$output" != *FAIL* ]]
}

@test "check_settings: keep fails when a seed is mounted" {
  mkdir -p "${ROOT_HOME}/.claude"
  echo '{"env":{"S":"V2"}}' > "${ROOT_HOME}/.claude/settings.json"
  echo '{}' > "$SEED_SETTINGS"
  EXPECT_SETTINGS=keep EXPECT_SETTINGS_SENTINEL=V2 run check_settings
  [[ "$output" == *"FAIL: settings-keep: seed present at ${SEED_SETTINGS}"* ]]
}

@test "check_settings: keep fails when the persisted file is gone" {
  EXPECT_SETTINGS=keep EXPECT_SETTINGS_SENTINEL=V2 run check_settings
  [[ "$output" == *"FAIL: settings-present:"* ]]
}

# --- main --------------------------------------------------------------------

# Stub every check but check_settings with a passing one.
stub_checks() {
  check_entrypoint_reached() { pass c1; }
  check_identity() { pass c2; }
  check_security() { pass c3; }
  check_path_order() { pass c4; }
  check_workspace_write() { pass c5; }
  check_credentials() { pass c6; }
  check_aws_state_masking() { pass c7; }
  check_api() { pass c8; }
  check_mask_set() { pass c9; }
}

@test "main exits 1 with RESULT: FAIL when any check fails" {
  stub_checks
  check_settings() { fail settings; }
  run main
  [ "$status" -eq 1 ]
  [[ "$output" == *"Results: 9 passed, 1 failed"* ]]
  [[ "$output" == *"RESULT: FAIL" ]]
  [[ "$output" != *"RESULT: PASS"* ]]
}

@test "main exits 0 with RESULT: PASS when every check passes" {
  stub_checks
  check_settings() { pass settings; }
  run main
  [ "$status" -eq 0 ]
  [[ "$output" == *"RESULT: PASS" ]]
}
