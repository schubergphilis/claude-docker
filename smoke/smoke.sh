#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# smoke.sh — parameterized smoke-test driver for the claude-docker entrypoint.
# Each invocation exercises one cell of the test matrix.
#
# Parameters (flags or env vars):
#   --uid=N         HOST_UID to pass into the container (default: $HOST_UID,
#                   else $(id -u)); must be numeric
#   --gid=N         HOST_GID to pass into the container (default: $HOST_GID,
#                   else $(id -g)); must be numeric
#   --optins=CSV    comma-separated credential opt-ins: aws,glab,tfe,api,az (default: "")
#   --volstate=S    cold|warm — cold=fresh volume, warm=run twice reusing a volume
#   --ro=0|1        1 = mount workspace :ro (robustness cell)
#   --ephemeral=0|1 1 = skip named volumes (--ephemeral mode)
#   --settings=0|1  1 = mount a settings.docker.json fixture at the seed path
#                   (entrypoint copies it to /root/.claude/settings.json);
#                   0 = no seed, asserts the entrypoint copes without one
#                   (default: 1). With --volstate=warm, the warm pass reruns
#                   against a rewritten fixture (V2 sentinel) to prove the
#                   entrypoint re-seeds, then a final no-seed pass proves a
#                   persisted settings.json is left as-is.
#   --image=TAG     Docker image to run (default: claude-code:local)
#   IMAGE=TAG       env var override for --image (checked if --image absent)
#   HOST_UID=N      env var default for --uid
#   HOST_GID=N      env var default for --gid
#
# A value outside the ones listed above is rejected, so a typo cannot quietly
# run a weaker cell (e.g. --ro=yes mounting the workspace read-write).
#
# Exit codes: 0 = cell passed, non-zero = cell failed.
#
# State shared between the functions below lives in globals: bash 3.2 (stock
# macOS, where this runs on the host) has no namerefs to pass arrays around.

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[smoke] $*"; }

die() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
parse_args() {
  local arg flag
  HOST_UID_ARG="${HOST_UID:-$(id -u)}"
  HOST_GID_ARG="${HOST_GID:-$(id -g)}"
  OPTINS=""
  VOLSTATE="cold"
  RO="0"
  EPHEMERAL="0"
  SETTINGS="1"
  IMAGE="${IMAGE:-claude-code:local}"

  for arg in "$@"; do
    case "$arg" in
      --uid=*)       HOST_UID_ARG="${arg#--uid=}" ;;
      --gid=*)       HOST_GID_ARG="${arg#--gid=}" ;;
      --optins=*)    OPTINS="${arg#--optins=}" ;;
      --volstate=*)  VOLSTATE="${arg#--volstate=}" ;;
      --ro=*)        RO="${arg#--ro=}" ;;
      --ephemeral=*) EPHEMERAL="${arg#--ephemeral=}" ;;
      --settings=*)  SETTINGS="${arg#--settings=}" ;;
      --image=*)     IMAGE="${arg#--image=}" ;;
      *) die "unknown argument '$arg'" ;;
    esac
  done

  case "${HOST_UID_ARG}" in ''|*[!0-9]*) die "uid must be numeric, got '${HOST_UID_ARG}'" ;; esac
  case "${HOST_GID_ARG}" in ''|*[!0-9]*) die "gid must be numeric, got '${HOST_GID_ARG}'" ;; esac
  case "${VOLSTATE}" in cold|warm) ;; *) die "--volstate must be cold or warm, got '${VOLSTATE}'" ;; esac
  for flag in "ro=${RO}" "ephemeral=${EPHEMERAL}" "settings=${SETTINGS}"; do
    case "${flag#*=}" in 0|1) ;; *) die "--${flag%%=*} must be 0 or 1, got '${flag#*=}'" ;; esac
  done
}

# Parse OPTINS into the WITH_* flags. IFS is scoped to the read, and the
# quoted array expansion keeps an opt-in from being glob-expanded.
parse_optins() {
  local optin
  local -a optins=()
  WITH_AWS=0
  WITH_GLAB=0
  WITH_TFE=0
  WITH_API=0
  WITH_AZ=0
  IFS=, read -ra optins <<< "${OPTINS}"
  for optin in "${optins[@]+"${optins[@]}"}"; do
    case "$optin" in
      aws)  WITH_AWS=1  ;;
      glab) WITH_GLAB=1 ;;
      tfe)  WITH_TFE=1  ;;
      api)  WITH_API=1  ;;
      az)   WITH_AZ=1   ;;
      *)    die "unknown opt-in: '$optin'" ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Temp workspace + cleanup
# ---------------------------------------------------------------------------
cleanup() {
  if [ -n "${VOL_NAME:-}" ]; then
    docker volume rm "${VOL_NAME}" >/dev/null 2>&1 || true
    docker volume rm "${VOL_NAME}-claude" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPROOT:-}"
}

setup_workspace() {
  local smoke_stage_root script_dir assert_script
  # Staged under $HOME, not the mktemp default: everything under TMPROOT is
  # bind-mounted into containers, and macOS docker VMs don't share the default
  # location (Colima shares only $HOME; /var/folders is invisible to it), so
  # sources there arrive as empty dirs in-container. macOS mktemp ignores even
  # an explicit TMPDIR override for no-template invocations, hence the explicit
  # template. Same rationale as run.sh's stage_root.
  smoke_stage_root="${HOME}/.cache/claude-docker"
  mkdir -p "${smoke_stage_root}" || return
  # Named volume used for warm-state testing; set by build_volume_args.
  VOL_NAME=""
  TMPROOT=$(mktemp -d "${smoke_stage_root}/smoke.XXXXXX") || return
  # Trap right away, so a failing mkdir/chmod/cp below still cleans up.
  trap cleanup EXIT
  WORKSPACE_HOST="${TMPROOT}/workspace"
  CREDS_HOST="${TMPROOT}/creds"
  CONTAINER_STDERR="${TMPROOT}/container_stderr.txt"
  SETTINGS_FIXTURE="${TMPROOT}/settings.docker.json"
  mkdir -p "${WORKSPACE_HOST}" "${CREDS_HOST}" || return
  # Make the workspace world-writable so a container running as a synthetic
  # HOST_UID (e.g. 501) that differs from the CI runner's UID can write into it —
  # in production the workspace is the user's own repo, owned by HOST_UID and
  # writable. Without this, the runner-owned (0755) dir blocks the non-runner UID
  # cells. Files the container creates are owned by HOST_UID; the host-side
  # ownership assertion reads that ownership back numerically.
  chmod 0777 "${WORKSPACE_HOST}" || return

  # Copy assert-in-container.sh into the workspace so the entrypoint can exec it.
  # Resolve this script's dir portably — `realpath` is GNU coreutils and is not
  # on stock macOS (where the Phase 2b job runs smoke.sh on the host directly).
  # BASH_SOURCE, not $0, so this also resolves when the file is sourced.
  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return
  assert_script="${script_dir}/assert-in-container.sh"
  if [ ! -f "${assert_script}" ]; then
    die "assert-in-container.sh not found at: ${assert_script}"
  fi
  cp "${assert_script}" "${WORKSPACE_HOST}/assert-in-container.sh" || return
  chmod +x "${WORKSPACE_HOST}/assert-in-container.sh"
}

# Container-side paths.
CONTAINER_WORKSPACE="/workspaces/smoke"
CONTAINER_ASSERT="${CONTAINER_WORKSPACE}/assert-in-container.sh"

# ---------------------------------------------------------------------------
# Credential opt-in mounts (mirror run.sh mount targets)
# ---------------------------------------------------------------------------

# Fake credential files/dirs created in CREDS_HOST.
# Each fake cred embeds the literal SMOKE-SENTINEL string. The in-container
# assertion greps the mounted path for it, proving the EXPECTED fixture was
# mounted (not some other host file a regression might bind in its place).
setup_fake_aws() {
  mkdir -p "${CREDS_HOST}/aws/sso" || return
  printf '[default]\nregion = us-east-1\n# SMOKE-SENTINEL-AWS\n' > "${CREDS_HOST}/aws/config" || return
  MOUNT_ARGS+=(
    "-v" "${CREDS_HOST}/aws/config:/root/.aws/config:ro"
    "-v" "${CREDS_HOST}/aws/sso:/root/.aws/sso:ro"
  )
  ENV_ARGS+=("-e" "AWS_PROFILE=default")
}

setup_fake_glab() {
  mkdir -p "${CREDS_HOST}/glab-cli" || return
  printf 'token = SMOKE-SENTINEL-GLAB\n' > "${CREDS_HOST}/glab-cli/config.yml" || return
  MOUNT_ARGS+=(
    "-v" "${CREDS_HOST}/glab-cli:/root/.config/glab-cli:ro"
  )
  ENV_ARGS+=("-e" "GITLAB_TOKEN=fake-gitlab-token")
}

setup_fake_tfe() {
  mkdir -p "${CREDS_HOST}/terraform.d" || return
  printf '{"credentials":{"app.terraform.io":{"token":"SMOKE-SENTINEL-TFE"}}}\n' \
    > "${CREDS_HOST}/terraform.d/credentials.tfrc.json" || return
  MOUNT_ARGS+=(
    "-v" "${CREDS_HOST}/terraform.d/credentials.tfrc.json:/root/.terraform.d/credentials.tfrc.json:ro"
  )
  ENV_ARGS+=("-e" "TF_TOKEN_app_terraform_io=fake-tfe-token")
}

# --api: a throwaway self-signed CA at run.sh's CLAUDE_DOCKER_API_CA mount
# target, so the entrypoint's update-ca-certificates step is exercised.
setup_fake_api() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=claude-docker smoke CA" \
    -keyout "${CREDS_HOST}/api-ca.key" -out "${CREDS_HOST}/api-ca.crt" >/dev/null 2>&1 \
    || die "openssl could not generate the --api smoke CA"
  chmod 0644 "${CREDS_HOST}/api-ca.crt" || return
  MOUNT_ARGS+=(
    "-v" "${CREDS_HOST}/api-ca.crt:/usr/local/share/ca-certificates/claude-docker-api.crt:ro"
  )
  ENV_ARGS+=("-e" "ANTHROPIC_BASE_URL=https://llm.smoke.invalid")
}

# --az mounts no host file; the PAT is the whole credential, so it carries the
# sentinel instead.
setup_fake_az() {
  ENV_ARGS+=("-e" "AZURE_DEVOPS_EXT_PAT=SMOKE-SENTINEL-AZ")
}

# ---------------------------------------------------------------------------
# Build docker run arguments
# ---------------------------------------------------------------------------
build_run_args() {
  local ws_suffix=""

  # Security flags — mirror run.sh exactly.
  SECURITY_ARGS=(
    "--init"
    "--security-opt" "no-new-privileges"
    "--cap-drop" "ALL"
    "--cap-add" "CHOWN"
    "--cap-add" "SETUID"
    "--cap-add" "SETGID"
    "--cap-add" "DAC_READ_SEARCH"
  )

  # Core env. EXPECT_SETTINGS / EXPECT_SETTINGS_SENTINEL are injected per pass
  # in run_container — the warm cell varies them between passes.
  ENV_ARGS=(
    "-e" "HOST_UID=${HOST_UID_ARG}"
    "-e" "HOST_GID=${HOST_GID_ARG}"
    "-e" "EXPECT_UID=${HOST_UID_ARG}"
    "-e" "EXPECT_GID=${HOST_GID_ARG}"
    "-e" "EXPECT_OPTINS=${OPTINS}"
    "-e" "EXPECT_RO=${RO}"
    "-e" "EXPECT_EPHEMERAL=${EPHEMERAL}"
    "-e" "WORKSPACE=${CONTAINER_WORKSPACE}"
  )

  # Workspace mount — :ro when RO=1.
  if [ "${RO}" = "1" ]; then
    ws_suffix=":ro"
  fi
  MOUNT_ARGS=(
    "-v" "${WORKSPACE_HOST}:${CONTAINER_WORKSPACE}${ws_suffix}"
  )

  # Settings fixture — mirrors run.sh's settings.docker.json forwarding: mounted
  # :ro at the seed path, entrypoint copies it to /root/.claude/settings.json.
  # The sentinel proves the seeded copy came from OUR fixture; the in-container
  # check also renames a tmp file over the copy — the regression that motivated
  # the seed-copy design (rename() over a single-file bind mount → EBUSY).
  # These three are mutable across warm-cell passes (see run_cell), so the
  # mount lives in its own array and run_container reads the current values
  # instead of baking them into ENV_ARGS.
  SETTINGS_SENTINEL="SMOKE-SENTINEL-SETTINGS"
  EXPECT_SETTINGS_MODE="${SETTINGS}"
  SETTINGS_MOUNT_ARGS=()
  if [ "${SETTINGS}" = "1" ]; then
    printf '{"env":{"SMOKE_SENTINEL":"%s"}}\n' "${SETTINGS_SENTINEL}" > "${SETTINGS_FIXTURE}" || return
    SETTINGS_MOUNT_ARGS=(
      "-v" "${SETTINGS_FIXTURE}:/run/claude-docker/settings.json:ro"
    )
  fi

  # Credential mounts for the granted opt-ins.
  if [ "${WITH_AWS}"  = "1" ]; then setup_fake_aws || return; fi
  if [ "${WITH_GLAB}" = "1" ]; then setup_fake_glab || return; fi
  if [ "${WITH_TFE}"  = "1" ]; then setup_fake_tfe || return; fi
  if [ "${WITH_API}"  = "1" ]; then setup_fake_api || return; fi
  if [ "${WITH_AZ}"   = "1" ]; then setup_fake_az; fi
}

# ---------------------------------------------------------------------------
# Volume / ephemeral handling
# Mirror run.sh: when EPHEMERAL=0 mount named volumes + tmpfs masks for
# non-granted opt-ins.  When EPHEMERAL=1 skip named volumes entirely.
# ---------------------------------------------------------------------------
build_volume_args() {
  VOLUME_ARGS=()
  if [ "${EPHEMERAL}" = "0" ]; then
    # For VOLSTATE=warm, reuse a named volume across two runs.
    if [ "${VOLSTATE}" = "warm" ]; then
      VOL_NAME="smoke-test-root-$$"
      VOLUME_ARGS=(
        "-v" "${VOL_NAME}:/root"
        "-v" "${VOL_NAME}-claude:/root/.claude"
      )
    else
      # cold: use anonymous volumes (Docker creates and discards them with --rm).
      VOLUME_ARGS=(
        "-v" "/root"
        "-v" "/root/.claude"
      )
    fi

    # tmpfs masks for non-granted opt-ins (mirrors run.sh).
    # --gh is not exercised by the smoke harness, so always mask it.
    VOLUME_ARGS+=("--tmpfs" "/root/.config/gh")
    [ "${WITH_GLAB}" = "0" ] && VOLUME_ARGS+=("--tmpfs" "/root/.config/glab-cli")
    [ "${WITH_TFE}"  = "0" ] && VOLUME_ARGS+=("--tmpfs" "/root/.terraform.d")
    [ "${WITH_AZ}"   = "0" ] && VOLUME_ARGS+=("--tmpfs" "/root/.azure")
    # AWS is masked in both directions, only the scope changes (see run.sh).
    # tests/test_masks.py asserts this mirror stays in step with run.sh — the
    # mirror is why a mask missing from run.sh cannot fail this suite on its own.
    # The if/else also keeps the block from ending on a `[ ] && ...` list.
    if [ "${WITH_AWS}" = "0" ]; then
      VOLUME_ARGS+=("--tmpfs" "/root/.aws")
    else
      VOLUME_ARGS+=("--tmpfs" "/root/.aws/cli/cache")
    fi
  fi
}

# ---------------------------------------------------------------------------
# Single-run helper
# ---------------------------------------------------------------------------
run_container() {
  # Capture stderr to a file for the host-side WARN assertion, and also
  # forward it to the terminal so CI logs show container output.
  # "${arr[@]+"${arr[@]}"}" is the set -u-safe empty-array expansion idiom:
  # it expands to the array's elements when non-empty, and to nothing when empty.
  local rc
  docker run --rm \
    "${SECURITY_ARGS[@]}" \
    "${VOLUME_ARGS[@]+"${VOLUME_ARGS[@]}"}" \
    "${MOUNT_ARGS[@]}" \
    "${SETTINGS_MOUNT_ARGS[@]+"${SETTINGS_MOUNT_ARGS[@]}"}" \
    "${ENV_ARGS[@]}" \
    -e "EXPECT_SETTINGS=${EXPECT_SETTINGS_MODE}" \
    -e "EXPECT_SETTINGS_SENTINEL=${SETTINGS_SENTINEL}" \
    "${IMAGE}" \
    "${CONTAINER_ASSERT}" \
    2>"${CONTAINER_STDERR}" || rc=$?
  # Forward captured stderr to the terminal so CI logs are readable.
  cat "${CONTAINER_STDERR}" >&2 || true
  return "${rc:-0}"
}

# ---------------------------------------------------------------------------
# Execute: one pass for a cold cell, the cold/warm/no-seed sequence for warm.
# ---------------------------------------------------------------------------
run_cell() {
  if [ "${VOLSTATE}" != "warm" ]; then
    run_container
    return
  fi
  # Each pass carries `|| return`: set -e alone is ignored when main runs
  # under `||` or bats `run`, and a failed pass must not fall through.
  # First run: cold — populates the named volume.
  log "Warm cell: running cold pass first..."
  run_container || return
  if [ "${SETTINGS}" = "1" ]; then
    # Rewrite the fixture IN PLACE with a second sentinel (truncate keeps the
    # inode, so the :ro bind mount sees the new content). The warm pass must
    # find V2, proving the entrypoint RE-SEEDED — overwrote the copy pass 1
    # left in the volume — which is the spec's "next container start re-seeds
    # settings.json from the host file" contract. Rerunning with the same
    # content would let a `[ -f ] || cp` re-implementation pass on pass 1's
    # leftovers.
    SETTINGS_SENTINEL="SMOKE-SENTINEL-SETTINGS-V2"
    printf '{"env":{"SMOKE_SENTINEL":"%s"}}\n' "${SETTINGS_SENTINEL}" > "${SETTINGS_FIXTURE}" || return
  fi
  log "Warm cell: cold pass done; running warm pass..."
  run_container || return
  if [ "${SETTINGS}" = "1" ]; then
    # Final pass with NO seed mounted: a warm volume holding a previously
    # persisted settings.json must be left as-is (spec: "No settings file" —
    # "whatever a previous run persisted in the home volume"). The V2
    # sentinel from the warm pass must survive untouched.
    SETTINGS_MOUNT_ARGS=()
    EXPECT_SETTINGS_MODE="keep"
    log "Warm cell: warm pass done; running no-seed pass (persisted settings kept)..."
    run_container || return
  fi
}

# ---------------------------------------------------------------------------
# Host-side assertions
# ---------------------------------------------------------------------------
assert_host() {
  local probe_file="${WORKSPACE_HOST}/smoke-probe.txt" probe_owner

  # 1 & 2. Probe file checks — skipped when RO=1 (workspace is :ro, container
  #         cannot write to it; the RO cell tests entrypoint EROFS robustness only).
  if [ "${RO}" = "0" ]; then
    # 1. The container wrote the probe file and it is non-empty.
    if [ ! -f "${probe_file}" ]; then
      die "host-side: probe file not created by container: ${probe_file}"
    fi
    if [ ! -s "${probe_file}" ]; then
      die "host-side: probe file is empty: ${probe_file}"
    fi
    log "host-side PASS: probe file exists and non-empty"

    # 2. Probe file owned by HOST_UID on the host. Bind mounts pass UIDs through
    #    numerically, so a file the container wrote as HOST_UID is owned by that
    #    same UID on the host — `stat` reads it back regardless of the runner's own
    #    UID (so this covers the uid=501 cell too). Skipped only for HOST_UID=0,
    #    where the file is root-owned and ownership round-trip is not the point.
    #    GNU `stat -c` first, BSD/macOS `stat -f` as the fallback.
    if [ "${HOST_UID_ARG}" != "0" ]; then
      probe_owner=$(stat -c '%u' "${probe_file}" 2>/dev/null || stat -f '%u' "${probe_file}" 2>/dev/null) \
        || die "host-side: could not stat probe file owner: ${probe_file}"
      if [ "${probe_owner}" = "${HOST_UID_ARG}" ]; then
        log "host-side PASS: probe file owned by ${HOST_UID_ARG}"
      else
        die "host-side: probe file owned by ${probe_owner}, expected ${HOST_UID_ARG}"
      fi
    fi
  fi

  # 3. Robustness: no spurious 'entrypoint: WARN' on stderr — asserted for EVERY
  #    cell, not just RO. The entrypoint only chowns /root + /root/.claude
  #    (entrypoint.sh:42), so the :ro *workspace* mount never trips the chown→EROFS
  #    filter; the mounts that DO sit under /root are the credential opt-in mounts
  #    (--aws/--glab/--tfe), so the opt-in cells are what actually pin the
  #    WARN-suppression filter (entrypoint.sh:44). Checking every cell ensures a
  #    triggering condition is covered. NOTE: CONTAINER_STDERR is overwritten per
  #    run_container(), so for a warm cell this reflects only the last pass —
  #    acceptable here since the passes differ only in the settings seed mount
  #    at /run, which the chown walk (the WARN source) never touches.
  if grep -q 'entrypoint: WARN' "${CONTAINER_STDERR}" 2>/dev/null; then
    die "host-side: unexpected 'entrypoint: WARN' on container stderr"
  fi
  log "host-side PASS: no spurious entrypoint WARN on stderr"
}

main() {
  set -euo pipefail
  local cell_desc
  # `|| return` on each step: set -e is ignored when main runs under `||` or
  # bats `run`, so it cannot be relied on to stop a failed step.
  parse_args "$@" || return
  parse_optins || return
  setup_workspace || return
  build_run_args || return
  build_volume_args || return

  cell_desc="uid=${HOST_UID_ARG} gid=${HOST_GID_ARG} optins='${OPTINS}' volstate=${VOLSTATE} ro=${RO} ephemeral=${EPHEMERAL} settings=${SETTINGS}"
  log "Cell: ${cell_desc}"
  log "Image: ${IMAGE}"

  run_cell || return
  assert_host || return
  log "Cell PASS: ${cell_desc}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
