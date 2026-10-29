#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# assert-in-container.sh — runs INSIDE the container as the dropped user.
# Invoked as the container command: entrypoint.sh calls
#   exec runuser -u claude -- /workspaces/smoke/assert-in-container.sh
# Reads expectations from env vars set by smoke.sh (via CLAUDE_DOCKER_TEST_ENTRY):
#   EXPECT_UID        expected numeric UID (matches HOST_UID forwarded by smoke.sh)
#   EXPECT_GID        expected primary GID (HOST_GID); checked when EXPECT_UID != 0
#   EXPECT_EPHEMERAL  1 = --ephemeral run: no volumes, so no AWS tmpfs mask to assert
#   EXPECT_OPTINS     comma-separated list of granted opt-ins (aws glab tfe api az), or empty
#   WORKSPACE         path to the bind-mounted workspace inside the container
#   EXPECT_RO         1 = workspace is :ro (skip write probe, only test entrypoint startup)
#   EXPECT_SETTINGS   1 = a settings fixture was mounted at the seed path; assert the
#                     entrypoint copied it to /root/.claude/settings.json and the copy
#                     is atomically replaceable. 0 = no seed on fresh volumes; assert
#                     nothing was seeded. keep = no seed this run, but a previous run
#                     persisted a settings.json in the warm volume; assert it survived.
#   EXPECT_SETTINGS_SENTINEL
#                     sentinel string the settings.json content must carry. Passed by
#                     smoke.sh rather than hardcoded here: the warm cell changes it
#                     between passes to prove re-seeding overwrites the previous copy.
# Accumulates per-check PASS/FAIL and exits non-zero at the end if any failed
# (so one regression doesn't hide the rest of the report).
#
# Filesystem locations, overridable so tests/bats can point them at fixtures.
# smoke.sh never sets them; the defaults are the real in-container paths.
PROC_STATUS="${PROC_STATUS:-/proc/self/status}"
PROC_MOUNTS="${PROC_MOUNTS:-/proc/self/mounts}"
ROOT_HOME="${ROOT_HOME:-/root}"
SEED_SETTINGS="${SEED_SETTINGS:-/run/claude-docker/settings.json}"
API_CA="${API_CA:-/usr/local/share/ca-certificates/claude-docker-api.crt}"
AUTH_PROXY_CA="${AUTH_PROXY_CA:-/usr/local/share/ca-certificates/claude-docker-auth-proxy.crt}"
CA_BUNDLE="${CA_BUNDLE:-/etc/ssl/certs/ca-certificates.crt}"

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
  local status_file="$PROC_STATUS"

  if [ ! -f "$status_file" ]; then
    fail "security: $status_file not found"
    return
  fi

  # awk alone, not grep | awk: a missing field yields an empty value (which
  # the assertions below report) instead of a pipefail abort of the run.
  local cap_eff cap_prm cap_amb cap_bnd nnp
  cap_eff=$(awk '/^CapEff:/{print $2}' "$status_file")
  cap_prm=$(awk '/^CapPrm:/{print $2}' "$status_file")
  cap_amb=$(awk '/^CapAmb:/{print $2}' "$status_file")
  cap_bnd=$(awk '/^CapBnd:/{print $2}' "$status_file")
  nnp=$(awk '/^NoNewPrivs:/{print $2}' "$status_file")

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
# 3. PATH ordering and the exported Go environment
# ---------------------------------------------------------------------------

# Index of an entry in the colon-separated PATH, or -1 when absent. Matches
# whole entries only, so /root/go/bin never matches inside /root/go/bin/foo.
path_index() {
  local want="$1" i=0 entry
  local IFS=:
  for entry in $PATH; do
    if [ "$entry" = "$want" ]; then
      printf '%s' "$i"
      return
    fi
    i=$((i + 1))
  done
  printf '%s' "-1"
}

assert_path_before() {
  local first="$1" second="$2"
  local a b
  a=$(path_index "$first")
  b=$(path_index "$second")
  if [ "$a" = "-1" ]; then
    fail "path-order: $first is not on PATH (PATH=$PATH)"
  elif [ "$b" = "-1" ]; then
    fail "path-order: $second is not on PATH (PATH=$PATH)"
  elif [ "$a" -lt "$b" ]; then
    pass "path-order: $first (#$a) precedes $second (#$b)"
  else
    fail "path-order: expected $first before $second, got #$a and #$b (PATH=$PATH)"
  fi
}

check_path_order() {
  # The image PATH survives the privilege drop — entrypoint.sh execs
  # `runuser -u claude` (not -l), so what this script sees IS the shipped
  # ordering. /root is the persistent claude-code-root volume, so both
  # /root/.local/bin (pip --user / uv tool install prefix) and /root/go/bin
  # (GOPATH default, `go install` target) are agent-writable and survive the
  # session. Neither may precede a system path: a binary one session leaves
  # there must not shadow git/gh/aws on a later run, in an unrelated workspace.
  # /usr/bin stands in for "the system paths" — it is where git and gh live.
  assert_path_before /usr/local/go/bin /usr/bin
  assert_path_before /usr/bin /root/.local/bin
  assert_path_before /usr/bin /root/go/bin

  # And the resolution actually lands on the system copy, not merely earlier in
  # a string — this is the invariant the ordering exists to buy.
  assert_eq "path-git-resolves-system" "$(command -v git)" "/usr/bin/git"

  # Go environment exported by the image (ENV), so it holds for docker run,
  # docker exec, and non-login shells alike rather than relying on `go env`
  # defaults. Spelled against a literal /root: Docker does not define HOME at
  # build time.
  assert_eq "GOROOT=/usr/local/go" "${GOROOT:-}" "/usr/local/go"
  assert_eq "GOPATH=/root/go" "${GOPATH:-}" "/root/go"
  assert_eq "GOBIN=/root/go/bin" "${GOBIN:-}" "/root/go/bin"
}

# ---------------------------------------------------------------------------
# 4. File ownership — write into the workspace, smoke.sh checks host ownership
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
# 5. Credential plumbing
# ---------------------------------------------------------------------------

# Mapping: opt-in name → container config path + env var to check.
# Format: "config_path:env_var" (env_var may be empty if not applicable)
optin_config_path() {
  case "$1" in
    aws)  echo "${ROOT_HOME}/.aws/config:AWS_PROFILE" ;;
    glab) echo "${ROOT_HOME}/.config/glab-cli:GITLAB_TOKEN" ;;
    tfe)  echo "${ROOT_HOME}/.terraform.d/credentials.tfrc.json:TF_TOKEN_app_terraform_io" ;;
    az)   echo "${ROOT_HOME}/.azure:AZURE_DEVOPS_EXT_PAT" ;;
    *)    echo "" ;;
  esac
}

# All known opt-ins in declaration order.
ALL_OPTINS=(aws glab tfe az)

check_credentials() {
  local optin g
  local -a granted_list=()
  IFS=',' read -ra granted_list <<< "${EXPECT_OPTINS:-}"

  for optin in "${ALL_OPTINS[@]}"; do
    local spec config_path env_var
    spec=$(optin_config_path "$optin")
    config_path="${spec%%:*}"
    env_var="${spec##*:}"

    # Determine whether this opt-in was granted.
    local granted=0
    for g in "${granted_list[@]}"; do
      if [ "$g" = "$optin" ]; then
        granted=1
        break
      fi
    done

    if [ "$granted" = "1" ] && [ "$optin" = "az" ]; then
      # --az mounts no host file (/root/.azure is plain volume state), so the
      # forwarded PAT is the fixture: it must be OUR sentinel.
      case "${AZURE_DEVOPS_EXT_PAT:-}" in
        *SMOKE-SENTINEL*) pass "optin-az-env: AZURE_DEVOPS_EXT_PAT carries the smoke sentinel" ;;
        *)                fail "optin-az-env: AZURE_DEVOPS_EXT_PAT missing or not the smoke fixture" ;;
      esac
    elif [ "$granted" = "1" ]; then
      # Config path must exist and be read-only (mounted :ro by run.sh).
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
      # --glab keeps the token in the auth-proxy sidecar: the agent sees only
      # the placeholder, and the session CA it reaches GitLab through is trusted.
      if [ "$optin" = "glab" ]; then
        if [ "${GITLAB_TOKEN:-}" = "claude-docker-proxy" ]; then
          pass "optin-glab-proxy: GITLAB_TOKEN is the auth-proxy placeholder"
        else
          fail "optin-glab-proxy: GITLAB_TOKEN is not the placeholder (real token forwarded?)"
        fi
        if [ -f "$AUTH_PROXY_CA" ]; then
          pass "optin-glab-proxy-ca: the auth-proxy session CA is mounted"
        else
          fail "optin-glab-proxy-ca: auth-proxy session CA missing"
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

# AWS needs its own check, and cannot be folded into the loop above.
# optin_config_path returns /root/.aws/config, and that value is shared with the
# granted branch, which asserts the path is read-only. /root/.aws is not — only
# the two entries mounted inside it are — so repointing the mapping at the
# directory would make the granted branch fail.
#
# The loop is also blind to what matters here: without --aws, /root/.aws/config
# is absent whether or not a mask exists, so the masked-aws assertion passed
# vacuously and the credential cache beside it went unexamined.
check_aws_state_masking() {
  local granted=0
  case ",${EXPECT_OPTINS:-}," in
    *,aws,*) granted=1 ;;
  esac

  # --ephemeral mounts no named volumes, so there is nothing to mask and run.sh
  # adds no tmpfs (the whole mask block is inside its EPHEMERAL=0 branch). The
  # property still worth asserting is the one the masks exist to provide: no
  # AWS state carried in from anywhere. Requiring a tmpfs here would fail the
  # ephemeral cell for doing exactly what it is supposed to do.
  if [ "${EXPECT_EPHEMERAL:-0}" = "1" ]; then
    local cache="${ROOT_HOME}/.aws/cli/cache"
    if [ ! -e "$cache" ] || [ "$(find "$cache" -mindepth 1 2>/dev/null | wc -l)" -eq 0 ]; then
      pass "ephemeral-aws: no AWS credential cache present (no volumes mounted)"
    else
      fail "ephemeral-aws: ${cache} is populated in an --ephemeral session"
    fi
    return
  fi

  local path label
  if [ "$granted" = "1" ]; then
    # Under --aws the mask narrows to the credential cache: the AWS CLI writes
    # assume-role/SSO-derived STS there, and /root is a shared persistent
    # volume, so it must not outlive this session.
    path="${ROOT_HOME}/.aws/cli/cache"
    label="aws-cache-masked"
  else
    path="${ROOT_HOME}/.aws"
    label="masked-aws-dir"
  fi

  if [ ! -e "$path" ]; then
    fail "${label}: ${path} does not exist (expected an empty tmpfs mask)"
    return
  fi

  local entry_count
  entry_count=$(find "$path" -mindepth 1 2>/dev/null | wc -l)
  if [ "$entry_count" -eq 0 ]; then
    pass "${label}: ${path} is present and empty (tmpfs mask)"
  else
    fail "${label}: ${path} unexpectedly populated ($entry_count entries)"
  fi

  # Under --aws the read-only host mounts must survive the narrower mask.
  if [ "$granted" = "1" ]; then
    if [ -f "${ROOT_HOME}/.aws/config" ]; then
      pass "aws-cache-masked-scope: ${ROOT_HOME}/.aws/config still visible under the cache mask"
    else
      fail "aws-cache-masked-scope: ${ROOT_HOME}/.aws/config hidden — mask is too broad"
    fi

    # This is the one mask that must stay WRITABLE. Every other mask exists to
    # deny access, but the AWS CLI writes its derived STS credentials into this
    # directory, so an unwritable mask would break `aws` under the very flag
    # that grants it. Nothing else guarantees it: entrypoint.sh's chown walk
    # runs `find /root ... -xdev`, which by design does not descend into a
    # tmpfs, so ownership here is whatever the mount gave us.
    if touch "${path}/__smoke_write_test" 2>/dev/null; then
      pass "aws-cache-writable: the cache mask accepts writes from the session user"
      rm -f "${path}/__smoke_write_test"
    else
      fail "aws-cache-writable: cannot write to ${path} as $(id -u):$(id -g) — the AWS CLI would fail to cache credentials under --aws"
    fi
  fi
}

# --api has no config path, so it can't ride check_credentials' shape. What
# matters: Claude Code is pointed at the auth-proxy sidecar with a placeholder
# credential (the real one stays in the sidecar), and the mounted private CA
# made it into the system bundle (the entrypoint's update-ca-certificates step).
check_api() {
  local ca="$API_CA" bundle="$CA_BUNDLE" ca_line=""
  case ",${EXPECT_OPTINS:-}," in
    *,api,*)
      if [ "${ANTHROPIC_BASE_URL:-}" = "http://claude-docker-api-proxy:8080" ]; then
        pass "optin-api-env: ANTHROPIC_BASE_URL points at the auth-proxy sidecar"
      else
        fail "optin-api-env: ANTHROPIC_BASE_URL is '${ANTHROPIC_BASE_URL:-<unset>}', not the sidecar"
      fi
      if [ "${ANTHROPIC_AUTH_TOKEN:-}" = "claude-docker-proxy" ]; then
        pass "optin-api-proxy: ANTHROPIC_AUTH_TOKEN is the auth-proxy placeholder"
      else
        fail "optin-api-proxy: ANTHROPIC_AUTH_TOKEN is not the placeholder (real token forwarded?)"
      fi
      # Line 2 is the first base64 line of the PEM body — unique to this CA.
      # It must be non-empty: grep -F "" matches any bundle.
      if [ -f "$ca" ]; then
        ca_line=$(sed -n 2p "$ca")
      fi
      if [ -n "$ca_line" ] && grep -qF -- "$ca_line" "$bundle" 2>/dev/null; then
        pass "optin-api-ca: mounted CA is in the system trust bundle"
      else
        fail "optin-api-ca: mounted CA missing from $bundle (update-ca-certificates not run?)"
      fi
      ;;
    *)
      if [ -n "${ANTHROPIC_BASE_URL:-}" ] || [ -e "$ca" ]; then
        fail "leak-api: endpoint env or CA present but opt-in 'api' was not granted"
      else
        pass "leak-api: no endpoint env or CA (opt-in off)"
      fi
      ;;
  esac
}

# The full tmpfs mask set under /root, by equality: a mask run.sh adds or drops
# without a matching update here (and a spec delta in external-cli-tools) fails
# the cell. Presence checks alone can't catch a dropped glab/tfe mask on a fresh
# volume — the path is empty either way.
check_mask_set() {
  local expected="" actual optins=",${EXPECT_OPTINS:-},"
  if [ "${EXPECT_EPHEMERAL:-0}" = "0" ]; then
    # smoke never passes --gh, so the gh mask is always on.
    expected="/root/.config/gh"
    case "$optins" in *,glab,*) ;; *) expected="$expected /root/.config/glab-cli" ;; esac
    case "$optins" in *,tfe,*)  ;; *) expected="$expected /root/.terraform.d" ;; esac
    case "$optins" in *,az,*)   ;; *) expected="$expected /root/.azure" ;; esac
    case "$optins" in
      *,aws,*) expected="$expected /root/.aws/cli/cache" ;;
      *)       expected="$expected /root/.aws" ;;
    esac
  fi
  # shellcheck disable=SC2086  # word-split of the space-separated list is intended
  expected=$(printf '%s\n' $expected | sort)
  actual=$(awk '$3 == "tmpfs" && ($2 == "/root" || $2 ~ /^\/root\//) { print $2 }' "$PROC_MOUNTS" | sort)
  if [ "$actual" = "$expected" ]; then
    pass "mask-set: tmpfs masks under /root are exactly [$(echo "$expected" | tr "\n" " ")]"
  else
    fail "mask-set: tmpfs masks under /root are [$(echo "$actual" | tr "\n" " ")], expected [$(echo "$expected" | tr "\n" " ")]"
  fi
}

# ---------------------------------------------------------------------------
# 6. Seeded settings — must be a writable copy, not a mount
# ---------------------------------------------------------------------------

check_settings() {
  local settings="${ROOT_HOME}/.claude/settings.json"
  local mode="${EXPECT_SETTINGS:-0}"

  if [ "$mode" = "0" ]; then
    # No seed mounted, fresh volumes: the entrypoint must start cleanly
    # without creating one. (The warm no-seed path — a previously persisted
    # settings.json left as-is — is mode=keep below.)
    if [ -e "$settings" ]; then
      fail "settings-absent: $settings exists but no seed was mounted"
    else
      pass "settings-absent: no settings file without a seed"
    fi
    return
  fi

  if [ "$mode" = "keep" ]; then
    # Warm volume, no seed this run: the entrypoint's seed block must not
    # touch the settings.json a previous run persisted. The shared checks
    # below assert it survived with the previous pass's sentinel and is
    # still atomically replaceable.
    if [ -e "$SEED_SETTINGS" ]; then
      fail "settings-keep: seed present at $SEED_SETTINGS but this pass expects none"
    else
      pass "settings-keep: no seed mounted this run"
    fi
  fi

  if [ ! -f "$settings" ]; then
    fail "settings-present: $settings missing (mode=$mode: seed copy did not run, or a persisted file was lost)"
    return
  fi
  pass "settings-present: $settings exists"

  # Content must carry the sentinel smoke.sh expects for THIS pass. The warm
  # cell reruns with a rewritten fixture, so matching the pass-specific
  # sentinel proves the entrypoint re-seeded (mode=1) or left the persisted
  # copy alone (mode=keep) — not merely that some settings.json exists.
  local sentinel="${EXPECT_SETTINGS_SENTINEL:-}"
  if [ -z "$sentinel" ]; then
    fail "settings-content: EXPECT_SETTINGS_SENTINEL not set (smoke.sh plumbing regression)"
  elif grep -qF -- "$sentinel" "$settings" 2>/dev/null; then
    pass "settings-content: settings.json carries expected sentinel '$sentinel'"
  else
    # Size only: settings.json may hold tokens, and this lands in the CI log.
    fail "settings-content: '$sentinel' not found in $settings ($(wc -c 2>/dev/null < "$settings" || echo '<unreadable>') bytes)"
  fi

  # The reason settings are copied instead of bind-mounted: Claude Code saves
  # settings by renaming a tmp file over settings.json, and rename() over a
  # mountpoint fails with EBUSY. Prove the rename path works.
  local tmp="${settings}.tmp.smoke"
  if cp "$settings" "$tmp" 2>/dev/null && mv "$tmp" "$settings" 2>/dev/null; then
    pass "settings-rename: tmp-file rename over settings.json succeeds"
  else
    rm -f "$tmp"
    fail "settings-rename: cannot atomically replace $settings (mountpoint or ownership regression)"
  fi
}

# ---------------------------------------------------------------------------
# 7. Robustness — entrypoint reached here, so it did not abort
# ---------------------------------------------------------------------------

check_entrypoint_reached() {
  # If we are executing at all, the entrypoint ran to completion and exec'd us.
  pass "entrypoint-reached: this script is running, entrypoint did not abort"
}

# ---------------------------------------------------------------------------
# 8. --egress-lock (EXPECT_EGRESS=1, driven by smoke/egress.sh via run.sh)
# ---------------------------------------------------------------------------
# The proxy-unaware probes are the load-bearing ones. A proxy-aware client
# failing to reach a blocked host only proves the proxy is configured. It says
# nothing about whether a raw socket can walk around it, and the --internal
# network exists to stop exactly that. smoke/egress.sh's fake gateway is
# example.com; any other non-provider host (example.org) must stay reachable.

# HTTP status for $2 via curl; $1 is the -w variable. Prints 000 on failure.
egress_code() {
  local out
  out=$(curl -s -o /dev/null -m 20 -w "%{$1}" "${@:3}" "$2" 2>/dev/null) || true
  printf '%s' "${out:-000}"
}

# entrypoint.sh approved the ANTHROPIC_API_KEY the agent sees (under --api,
# the sidecar's placeholder), so a fresh ~/.claude.json doesn't send onboarding
# to api.anthropic.com for a connectivity check. Claude Code stores the key's
# last 20 characters, or all of a shorter one: the placeholder
# `claude-docker-proxy` is 19, and bash's ${var: -20} would be empty for it.
check_egress_api_key() {
  local key_id="${ANTHROPIC_API_KEY:-}"
  [ "${#key_id}" -gt 20 ] && key_id="${key_id: -20}"
  if [ -n "${ANTHROPIC_API_KEY:-}" ] \
     && jq -e --arg id "$key_id" '.customApiKeyResponses.approved | index([$id])' \
          "$ROOT_HOME/.claude.json" >/dev/null 2>&1; then
    pass "egress-api-key: ANTHROPIC_API_KEY approved in ~/.claude.json"
  else
    fail "egress-api-key: ANTHROPIC_API_KEY not approved in ~/.claude.json"
  fi
}

check_egress() {
  if [ -n "${https_proxy:-}" ] && [ "${https_proxy:-}" = "${HTTPS_PROXY:-}" ]; then
    pass "egress-env: https_proxy/HTTPS_PROXY set ($https_proxy)"
  else
    fail "egress-env: https_proxy/HTTPS_PROXY missing or inconsistent"
  fi

  if [ -n "${EXPECT_EGRESS_ENDPOINT_PORT:-}" ]; then
    # The endpoint is github.com on an SSH port (tests/smoke/egress.sh --endpoint-port):
    # squid tunnels to it (http_connect 200; the TLS handshake with sshd then
    # fails, which doesn't matter), while the same port on any other host stays
    # refused. Both are squid's decision, so 403 means a rule refused it.
    local ep_port="$EXPECT_EGRESS_ENDPOINT_PORT"
    assert_eq "egress-endpoint-port: CONNECT to the endpoint's own port (github.com:$ep_port) allowed" \
      "$(egress_code http_connect "https://github.com:$ep_port/")" "200"
    assert_eq "egress-endpoint-port: the same port on another host (example.org:$ep_port) refused" \
      "$(egress_code http_connect "https://example.org:$ep_port/")" "403"
  else
    assert_eq "egress-endpoint: the model endpoint (example.com) via proxy" \
      "$(egress_code http_code https://example.com/)" "200"
  fi
  if [ "${EXPECT_EGRESS_API_PROXY:-0}" = "1" ]; then
    # --api: squid passes the plain-HTTP hop to the auth-proxy sidecar on its
    # port 8080. Whatever the upstream answers, a 403 is squid refusing it and
    # 000 a broken chain.
    local api_code
    api_code=$(egress_code http_code http://claude-docker-api-proxy:8080/)
    case "$api_code" in
      403|000) fail "egress-api-proxy: the --api auth-proxy sidecar via proxy (HTTP $api_code)" ;;
      *) pass "egress-api-proxy: the --api auth-proxy sidecar via proxy (HTTP $api_code)" ;;
    esac
  fi
  assert_eq "egress-open: a non-model host (example.org) via proxy" \
    "$(egress_code http_code https://example.org/)" "200"
  assert_eq "egress-provider: CONNECT api.anthropic.com refused by proxy" \
    "$(egress_code http_connect https://api.anthropic.com/)" "403"
  assert_eq "egress-provider: CONNECT claude.ai refused by proxy" \
    "$(egress_code http_connect https://claude.ai/)" "403"
  # Claude Code's managed settings pin the endpoint over any project setting
  # (tests/integration/managed-settings-precedence.sh proves the precedence). Here: they
  # are present, name this session's endpoint and squid (the container's own
  # proxy env), switch the other backends off, and the agent can neither
  # change them nor add a file beside them.
  local ms=/etc/claude-code/managed-settings.json ms_json px="${https_proxy:-}"
  ms_json=$(jq -c '.env' "$ms" 2>/dev/null) || ms_json=""
  assert_eq "egress-managed: managed settings pin the endpoint and proxy env, other backends off" "$ms_json" \
    "{\"ANTHROPIC_BASE_URL\":\"${EXPECT_EGRESS_MANAGED_URL:-}\",\"http_proxy\":\"$px\",\"https_proxy\":\"$px\",\"HTTP_PROXY\":\"$px\",\"HTTPS_PROXY\":\"$px\",\"no_proxy\":\"localhost,127.0.0.1,::1\",\"NO_PROXY\":\"localhost,127.0.0.1,::1\",\"CLAUDE_CODE_USE_GATEWAY\":\"0\",\"CLAUDE_CODE_USE_BEDROCK\":\"0\",\"CLAUDE_CODE_USE_FOUNDRY\":\"0\",\"CLAUDE_CODE_USE_ANTHROPIC_AWS\":\"0\",\"CLAUDE_CODE_USE_ANTHROPIC_GOOGLE_CLOUD\":\"0\",\"CLAUDE_CODE_USE_MANTLE\":\"0\",\"CLAUDE_CODE_USE_VERTEX\":\"0\"}"
  if ( : >>"$ms" ) 2>/dev/null; then
    fail "egress-managed-ro: the agent can write $ms"
  else
    pass "egress-managed-ro: $ms is read-only to the agent"
  fi
  if ( : >/etc/claude-code/extra.json ) 2>/dev/null; then
    fail "egress-managed-dir: the agent can add files to /etc/claude-code"
  else
    pass "egress-managed-dir: /etc/claude-code is not writable by the agent"
  fi

  check_egress_api_key

  if [ "${CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC:-}" = "1" ]; then
    pass "egress-telemetry: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1"
  else
    fail "egress-telemetry: CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC not set"
  fi
  if [ "${CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL:-}" = "1" ]; then
    pass "egress-marketplace: CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL=1"
  else
    fail "egress-marketplace: CLAUDE_CODE_DISABLE_OFFICIAL_MARKETPLACE_AUTOINSTALL not set"
  fi

  # No route: a public IP, without the proxy.
  if curl -s -o /dev/null -m 10 --noproxy '*' http://1.1.1.1/ 2>/dev/null; then
    fail "egress-bypass: proxy-unaware curl reached 1.1.1.1 by IP"
  else
    pass "egress-bypass: proxy-unaware curl to a public IP fails"
  fi
  if getent hosts example.org >/dev/null 2>&1; then
    fail "egress-dns: example.org resolves inside the agent container (DNS side channel)"
  else
    pass "egress-dns: external names do not resolve inside the agent container"
  fi

  # Denies above the allows. no_proxy is cleared for the localhost probe so
  # curl sends it to the proxy (where 'localhost' resolves to the proxy's own
  # loopback) instead of dialling the agent's own loopback.
  assert_eq "egress-metadata: 169.254.169.254 refused by proxy" \
    "$(egress_code http_code http://169.254.169.254/latest/meta-data/)" "403"
  assert_eq "egress-loopback: a name resolving to the proxy's loopback refused" \
    "$(no_proxy='' NO_PROXY='' egress_code http_code http://localhost/)" "403"
  assert_eq "egress-port: CONNECT to a non-443 port refused" \
    "$(egress_code http_connect https://example.com:8443/)" "403"

  if [ "${EXPECT_EGRESS_GH:-0}" = "1" ]; then
    # --cacert replaces the default bundle, so a completed handshake proves the
    # auth-proxy sidecar terminated TLS (squid routed api.github.com to it). /user needs
    # a token and this probe sends none, so GitHub's 401 message tells the two
    # apart: "Bad credentials" means the sidecar injected smoke's fake token,
    # "Requires authentication" means it did not. A 502 would be the sidecar
    # failing upstream, 000 the chain broken.
    local gh_out gh_code gh_body
    gh_out=$(curl -s -m 20 -w '\n%{http_code}' \
      --cacert /usr/local/share/ca-certificates/claude-docker-auth-proxy.crt \
      https://api.github.com/user 2>/dev/null) || true
    gh_code=${gh_out##*$'\n'}
    gh_body=${gh_out%$'\n'*}
    if [ "$gh_code" = "401" ] && [[ "$gh_body" == *'"Bad credentials"'* ]]; then
      pass "egress-gh: api.github.com via proxy → auth-proxy sidecar → GitHub, token injected (401 Bad credentials)"
    else
      fail "egress-gh: api.github.com via proxy → auth-proxy sidecar did not inject the token (HTTP ${gh_code:-000}: $(printf '%s' "$gh_body" | tr -d '\n' | cut -c1-120))"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  set -euo pipefail

  echo "=== assert-in-container starting (UID=$(id -u) GID=$(id -g)) ==="

  if [ "${EXPECT_EGRESS:-0}" = "1" ]; then
    # run.sh-driven cell: only the checks that hold for a run.sh session. The
    # capability check stays in: the egress boundary must not cost a capability.
    check_entrypoint_reached
    check_identity
    check_security
    check_egress
    echo "==="
    echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    if [ "$FAIL_COUNT" -gt 0 ]; then
      echo "RESULT: FAIL"
      exit 1
    fi
    echo "RESULT: PASS"
    return 0
  fi

  check_entrypoint_reached
  check_identity
  check_security
  check_path_order
  check_workspace_write
  check_credentials
  check_aws_state_masking
  check_api
  check_mask_set
  check_settings

  echo "==="
  echo "Results: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"

  if [ "$FAIL_COUNT" -gt 0 ]; then
    echo "RESULT: FAIL"
    exit 1
  fi
  echo "RESULT: PASS"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
