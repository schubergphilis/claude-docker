#!/usr/bin/env bash
# assert-in-container.sh — runs INSIDE the container as the dropped user.
# Invoked as the container command: entrypoint.sh calls
#   exec runuser -u claude -- /workspaces/smoke/assert-in-container.sh
# Reads expectations from env vars set by smoke.sh:
#   EXPECT_UID        expected numeric UID (matches HOST_UID forwarded by smoke.sh)
#   EXPECT_OPTINS     comma-separated list of granted opt-ins (aws glab tfe), or empty
#   WORKSPACE         path to the bind-mounted workspace inside the container
#   EXPECT_RO         1 = workspace is :ro (skip write probe, only test entrypoint startup)
# Accumulates per-check PASS/FAIL and exits non-zero at the end if any failed
# (so one regression doesn't hide the rest of the report).
set -euo pipefail

PASS_COUNT=0
FAIL_COUNT=0

# ---------------------------------------------------------------------------
# Assertion helpers
# ---------------------------------------------------------------------------

pass() {
  echo "PASS: $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "FAIL: $1"
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

assert_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then
    pass "$label: got '$got'"
  else
    fail "$label: expected '$want', got '$got'"
  fi
}

# Run a command and assert it fails with a substring matching the read-only
# filesystem error (uutils coreutils on ubuntu:26.04 emits "Read-only file
# system"; GNU coreutils emits the same string — match the common substring).
# Handles both directory paths (creates a sentinel file inside) and file paths
# (attempts to overwrite the file with tee).
assert_write_fails_ro() {
  local label="$1" path="$2"
  local out
  # Choose a write operation depending on whether path is a directory or file.
  if [ -d "$path" ]; then
    # Directory: try to create a sentinel file inside it.
    # Redirect stderr to stdout so we can grep the combined output.
    if out=$(touch "${path}/__smoke_write_test" 2>&1); then
      fail "$label: write to dir '${path}' succeeded (expected EROFS)"
      rm -f "${path}/__smoke_write_test"
    else
      if echo "$out" | grep -q "Read-only file system"; then
        pass "$label: write to dir blocked with read-only-filesystem error"
      else
        fail "$label: write to dir blocked but not by EROFS ('$out')"
      fi
    fi
  else
    # File: try to append to it.
    if out=$(tee -a "${path}" </dev/null 2>&1); then
      fail "$label: write to file '${path}' succeeded (expected EROFS)"
    else
      if echo "$out" | grep -q "Read-only file system"; then
        pass "$label: write to file blocked with read-only-filesystem error"
      else
        fail "$label: write to file blocked but not by EROFS ('$out')"
      fi
    fi
  fi
}

# ---------------------------------------------------------------------------
# 1. Identity checks
# ---------------------------------------------------------------------------

check_identity() {
  local actual_uid actual_gids home_val

  actual_uid=$(id -u)
  assert_eq "UID=EXPECT_UID" "$actual_uid" "${EXPECT_UID:-0}"

  # The process should have exactly ONE GID (no inherited sudo/adm/plugdev).
  # `id -G` returns space-separated list of all gids.
  actual_gids=$(id -G)
  local gid_count
  gid_count=$(printf '%s' "$actual_gids" | wc -w)
  if [ "$gid_count" -eq 1 ]; then
    pass "single-group: only primary GID present (id -G='$actual_gids')"
  else
    fail "single-group: expected exactly 1 GID, got $gid_count ('$actual_gids')"
  fi

  # And it must be the EXPECTED primary GID — a regression assigning claude to
  # gid 0 (root) as its single group would pass the count check above. Skip for
  # the root-legacy cell, where the process keeps gid 0 (not HOST_GID).
  if [ "${EXPECT_UID:-0}" != "0" ]; then
    assert_eq "primary-GID=EXPECT_GID" "$(id -g)" "${EXPECT_GID:-0}"
  fi

  # HOME must be /root regardless of HOST_UID (kept for mount-path compatibility).
  home_val="${HOME:-}"
  assert_eq "HOME=/root" "$home_val" "/root"
}

# ---------------------------------------------------------------------------
# 2. Security posture — capabilities and no-new-privs
# ---------------------------------------------------------------------------

check_security() {
  local status_file="/proc/self/status"

  if [ ! -f "$status_file" ]; then
    fail "security: /proc/self/status not found"
    return
  fi

  local cap_eff cap_prm cap_amb cap_bnd nnp
  cap_eff=$(grep '^CapEff:' "$status_file" | awk '{print $2}')
  cap_prm=$(grep '^CapPrm:' "$status_file" | awk '{print $2}')
  cap_amb=$(grep '^CapAmb:' "$status_file" | awk '{print $2}')
  cap_bnd=$(grep '^CapBnd:' "$status_file" | awk '{print $2}')
  nnp=$(grep '^NoNewPrivs:' "$status_file" | awk '{print $2}')

  # Universal invariants — these hold regardless of HOST_UID (including the
  # root-legacy path), so assert them BEFORE the uid=0 branch below.
  # no-new-privileges and the absence of setuid-root binaries are exactly the
  # controls that bound blast radius if the root path is ever entered, so the
  # root cell is the one place we most want them confirmed.
  assert_eq "NoNewPrivs=1" "$nnp" "1"

  # Setuid-root binaries: the base Ubuntu image ships the usual set (su, mount,
  # passwd, chsh, chfn, gpasswd, ssh-keysign, …). Under no-new-privileges
  # (asserted above) the kernel ignores the setuid bit, so NONE of them can
  # escalate — NoNewPrivs is the real control, not their absence. We therefore
  # don't fail on the inert base set (that would just track Ubuntu's package
  # list); we assert the one thing that WOULD matter: `sudo` must not be present,
  # since a sudo install is a deliberate escalation path the cap-drop model
  # forbids and a clear regression. The inventory is logged for visibility.
  local setuid_files
  setuid_files=$(find / -xdev -perm -4000 -type f 2>/dev/null | tr '\n' ' ' || true)
  echo "  (info) setuid-root binaries present (inert under NoNewPrivs): ${setuid_files:-<none>}"
  if command -v sudo >/dev/null 2>&1; then
    fail "no-sudo: sudo is present on PATH — an escalation path the cap-drop model forbids"
  else
    pass "no-sudo: sudo not installed (no escalation path beyond the inert base setuid set)"
  fi

  # Root-legacy path: with HOST_UID=0 the entrypoint execs directly as root
  # (entrypoint.sh :11-13) and never drops privileges, so root legitimately
  # retains effective caps. The dropped-privilege posture below does NOT apply;
  # asserting CapEff==0 here would wrongly fail a correct image.
  if [ "${EXPECT_UID:-0}" = "0" ]; then
    pass "security: HOST_UID=0 root-legacy path — cap-drop posture N/A (runs as root by design)"
    return
  fi

  # Dropped-privilege posture: CapEff/CapPrm/CapAmb must all be zero after
  # runuser drops UID 0. CapBnd retains the --cap-add set but is inert under
  # NoNewPrivs. Bit decomposition of the expected 0xc5 bounding set:
  #   CAP_CHOWN          (0) → bit 0 → 0x001
  #   CAP_DAC_READ_SEARCH(2) → bit 2 → 0x004
  #   CAP_SETGID         (6) → bit 6 → 0x040
  #   CAP_SETUID         (7) → bit 7 → 0x080   sum = 0xc5 = 197
  assert_eq "CapEff=0" "$cap_eff" "0000000000000000"
  assert_eq "CapPrm=0" "$cap_prm" "0000000000000000"
  assert_eq "CapAmb=0" "$cap_amb" "0000000000000000"

  # CapBnd and NoNewPrivs are a joint assertion: a non-empty bounding set is
  # only safe when no-new-privileges is also set.
  if [ "$cap_bnd" = "00000000000000c5" ] && [ "$nnp" = "1" ]; then
    pass "CapBnd+NoNewPrivs: bounding set=0x${cap_bnd} is inert under NoNewPrivs=${nnp}"
  else
    fail "CapBnd+NoNewPrivs: expected CapBnd=00000000000000c5 and NoNewPrivs=1, got CapBnd=${cap_bnd} NoNewPrivs=${nnp}"
  fi
}

# ---------------------------------------------------------------------------
# 3. File ownership — write into the workspace, smoke.sh checks host ownership
# ---------------------------------------------------------------------------

check_workspace_write() {
  # Skip the write probe when the workspace is mounted :ro (RO cell).
  # The RO cell tests entrypoint EROFS robustness, not workspace writability.
  if [ "${EXPECT_RO:-0}" = "1" ]; then
    pass "workspace-write: skipped (EXPECT_RO=1, workspace is :ro)"
    return
  fi

  local ws="${WORKSPACE:-/workspaces/smoke}"
  local probe_file="${ws}/smoke-probe.txt"

  if printf '%s\n' "smoke-write-$$" > "$probe_file"; then
    pass "workspace-write: created $probe_file"
  else
    fail "workspace-write: could not write to $probe_file"
  fi
}

# ---------------------------------------------------------------------------
# 4. Credential plumbing
# ---------------------------------------------------------------------------

# Mapping: opt-in name → container config path + env var to check.
# Format: "config_path:env_var" (env_var may be empty if not applicable)
optin_config_path() {
  case "$1" in
    aws)  echo "/root/.aws/config:AWS_PROFILE" ;;
    glab) echo "/root/.config/glab-cli:GITLAB_TOKEN" ;;
    tfe)  echo "/root/.terraform.d/credentials.tfrc.json:TF_TOKEN_app_terraform_io" ;;
    *)    echo "" ;;
  esac
}

# All known opt-ins in declaration order.
ALL_OPTINS="aws glab tfe"

check_credentials() {
  local granted_csv="${EXPECT_OPTINS:-}"

  # shellcheck disable=SC2086  # word-split on ALL_OPTINS is intentional (space-separated list)
  for optin in $ALL_OPTINS; do
    local spec config_path env_var
    spec=$(optin_config_path "$optin")
    config_path="${spec%%:*}"
    env_var="${spec##*:}"

    # Determine whether this opt-in was granted.
    local granted=0
    if [ -n "$granted_csv" ]; then
      local IFS=','
      # shellcheck disable=SC2086  # word-split on comma-separated list is intentional
      for g in $granted_csv; do
        if [ "$g" = "$optin" ]; then
          granted=1
          break
        fi
      done
    fi

    if [ "$granted" = "1" ]; then
      # Config path must exist and be read-only (mounted :ro by smoke.sh).
      if [ -e "$config_path" ]; then
        pass "optin-${optin}: config path exists: $config_path"
      else
        fail "optin-${optin}: config path missing: $config_path"
      fi
      assert_write_fails_ro "optin-${optin}-ro" "$config_path"

      # The mounted content must be OUR fixture (carries the SMOKE-SENTINEL
      # string). This proves the EXPECTED file was mounted, not merely that
      # *some* file is present — a regression bind-mounting a different host
      # file (e.g. ~/.aws/credentials instead of ~/.aws/config) is caught here.
      if grep -rqI "SMOKE-SENTINEL" "$config_path" 2>/dev/null; then
        pass "optin-${optin}-content: mounted fixture carries the smoke sentinel"
      else
        fail "optin-${optin}-content: SMOKE-SENTINEL not found under $config_path (wrong file mounted?)"
      fi

      # Forward env var must be present — smoke.sh always exports it for a
      # granted opt-in, so absence is a forwarding regression (fail-closed).
      if [ -n "$env_var" ]; then
        if [ -n "${!env_var:-}" ]; then
          pass "optin-${optin}-env: ${env_var} is forwarded"
        else
          fail "optin-${optin}-env: ${env_var} expected but not set (forwarding regression)"
        fi
      fi
    else
      # Config path must be absent or masked (empty tmpfs from run.sh).
      if [ ! -e "$config_path" ]; then
        pass "masked-${optin}: config path absent: $config_path"
      else
        # It may exist as an empty tmpfs mount — acceptable.
        local entry_count
        entry_count=$(find "$config_path" -maxdepth 1 2>/dev/null | wc -l)
        if [ "$entry_count" -le 1 ]; then
          pass "masked-${optin}: config path is present but empty (tmpfs mask): $config_path"
        else
          fail "masked-${optin}: config path unexpectedly populated when opt-in is off: $config_path"
        fi
      fi

      # The forward env var must NOT be set when the opt-in is off — a regression
      # forwarding a token without its opt-in flag would leak it (assume-breach).
      if [ -n "$env_var" ] && [ -n "${!env_var:-}" ]; then
        fail "leak-${optin}: ${env_var} is set but opt-in '${optin}' was not granted"
      else
        pass "leak-${optin}: ${env_var:-<none>} not forwarded (opt-in off)"
      fi
    fi
  done
}

# ---------------------------------------------------------------------------
# 5. Robustness — entrypoint reached here, so it did not abort
# ---------------------------------------------------------------------------

check_entrypoint_reached() {
  # If we are executing at all, the entrypoint ran to completion and exec'd us.
  pass "entrypoint-reached: this script is running, entrypoint did not abort"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

echo "=== assert-in-container starting (UID=$(id -u) GID=$(id -g)) ==="

check_entrypoint_reached
check_identity
check_security
check_workspace_write
check_credentials

echo "==="
echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

if [ "$FAIL_COUNT" -gt 0 ]; then
  echo "RESULT: FAIL"
  exit 1
fi
echo "RESULT: PASS"
