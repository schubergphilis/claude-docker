#!/usr/bin/env bash
# smoke.sh — parameterized smoke-test driver for the claude-docker entrypoint.
# Each invocation exercises one cell of the test matrix.
#
# Parameters (flags or env vars):
#   --uid=N         HOST_UID to pass into the container (default: $(id -u))
#   --optins=CSV    comma-separated credential opt-ins: aws,glab,tfe (default: "")
#   --volstate=S    cold|warm — cold=fresh volume, warm=run twice reusing a volume
#   --ro=0|1        1 = mount workspace :ro (robustness cell)
#   --ephemeral=0|1 1 = skip named volumes (--ephemeral mode)
#   --image=TAG     Docker image to run (default: claude-code:local)
#   IMAGE=TAG       env var override for --image (checked if --image absent)
#
# Exit codes: 0 = cell passed, non-zero = cell failed.
set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
HOST_UID_ARG="${HOST_UID:-$(id -u)}"
OPTINS=""
VOLSTATE="cold"
RO="0"
EPHEMERAL="0"
IMAGE="${IMAGE:-claude-code:local}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
for arg in "$@"; do
  case "$arg" in
    --uid=*)       HOST_UID_ARG="${arg#--uid=}" ;;
    --optins=*)    OPTINS="${arg#--optins=}" ;;
    --volstate=*)  VOLSTATE="${arg#--volstate=}" ;;
    --ro=*)        RO="${arg#--ro=}" ;;
    --ephemeral=*) EPHEMERAL="${arg#--ephemeral=}" ;;
    --image=*)     IMAGE="${arg#--image=}" ;;
    *) echo "smoke.sh: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

HOST_GID_ARG="${HOST_GID:-$(id -g)}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[smoke] $*"; }

die() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Temp workspace + cleanup
# ---------------------------------------------------------------------------
TMPROOT=$(mktemp -d)
WORKSPACE_HOST="${TMPROOT}/workspace"
CREDS_HOST="${TMPROOT}/creds"
mkdir -p "${WORKSPACE_HOST}" "${CREDS_HOST}"
# Make the workspace world-writable so a container running as a synthetic
# HOST_UID (e.g. 501) that differs from the CI runner's UID can write into it —
# in production the workspace is the user's own repo, owned by HOST_UID and
# writable. Without this, the runner-owned (0755) dir blocks the non-runner UID
# cells. Files the container creates are owned by HOST_UID; the host-side
# ownership assertion below only runs when HOST_UID matches the runner so it
# can read that ownership back.
chmod 0777 "${WORKSPACE_HOST}"

# Named volume used for warm-state testing.
VOL_NAME=""
CONTAINER_STDERR="${TMPROOT}/container_stderr.txt"

cleanup() {
  if [ -n "${VOL_NAME}" ]; then
    docker volume rm "${VOL_NAME}" >/dev/null 2>&1 || true
    docker volume rm "${VOL_NAME}-claude" >/dev/null 2>&1 || true
  fi
  rm -rf "${TMPROOT}"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Copy assert-in-container.sh into the workspace so the entrypoint can exec it.
# ---------------------------------------------------------------------------
ASSERT_SCRIPT="$(dirname "$(realpath "$0")")/assert-in-container.sh"
if [ ! -f "${ASSERT_SCRIPT}" ]; then
  die "assert-in-container.sh not found at: ${ASSERT_SCRIPT}"
fi
cp "${ASSERT_SCRIPT}" "${WORKSPACE_HOST}/assert-in-container.sh"
chmod +x "${WORKSPACE_HOST}/assert-in-container.sh"

# Container-side paths.
CONTAINER_WORKSPACE="/workspaces/smoke"
CONTAINER_ASSERT="${CONTAINER_WORKSPACE}/assert-in-container.sh"

# ---------------------------------------------------------------------------
# Build docker run arguments
# ---------------------------------------------------------------------------

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

# Core env.
ENV_ARGS=(
  "-e" "HOST_UID=${HOST_UID_ARG}"
  "-e" "HOST_GID=${HOST_GID_ARG}"
  "-e" "EXPECT_UID=${HOST_UID_ARG}"
  "-e" "EXPECT_GID=${HOST_GID_ARG}"
  "-e" "EXPECT_OPTINS=${OPTINS}"
  "-e" "EXPECT_RO=${RO}"
  "-e" "WORKSPACE=${CONTAINER_WORKSPACE}"
)

# Workspace mount — :ro when RO=1.
WS_SUFFIX=""
[ "${RO}" = "1" ] && WS_SUFFIX=":ro"
MOUNT_ARGS=(
  "-v" "${WORKSPACE_HOST}:${CONTAINER_WORKSPACE}${WS_SUFFIX}"
)

# ---------------------------------------------------------------------------
# Credential opt-in mounts (mirror run.sh mount targets)
# ---------------------------------------------------------------------------

# Fake credential files/dirs created in CREDS_HOST.
# Each fake cred embeds the literal SMOKE-SENTINEL string. The in-container
# assertion greps the mounted path for it, proving the EXPECTED fixture was
# mounted (not some other host file a regression might bind in its place).
setup_fake_aws() {
  mkdir -p "${CREDS_HOST}/aws/sso"
  printf '[default]\nregion = us-east-1\n# SMOKE-SENTINEL-AWS\n' > "${CREDS_HOST}/aws/config"
  MOUNT_ARGS+=(
    "-v" "${CREDS_HOST}/aws/config:/root/.aws/config:ro"
    "-v" "${CREDS_HOST}/aws/sso:/root/.aws/sso:ro"
  )
  ENV_ARGS+=("-e" "AWS_PROFILE=default")
}

setup_fake_glab() {
  mkdir -p "${CREDS_HOST}/glab-cli"
  printf 'token = SMOKE-SENTINEL-GLAB\n' > "${CREDS_HOST}/glab-cli/config.yml"
  MOUNT_ARGS+=(
    "-v" "${CREDS_HOST}/glab-cli:/root/.config/glab-cli:ro"
  )
  ENV_ARGS+=("-e" "GITLAB_TOKEN=fake-gitlab-token")
}

setup_fake_tfe() {
  mkdir -p "${CREDS_HOST}/terraform.d"
  printf '{"credentials":{"app.terraform.io":{"token":"SMOKE-SENTINEL-TFE"}}}\n' \
    > "${CREDS_HOST}/terraform.d/credentials.tfrc.json"
  MOUNT_ARGS+=(
    "-v" "${CREDS_HOST}/terraform.d/credentials.tfrc.json:/root/.terraform.d/credentials.tfrc.json:ro"
  )
  ENV_ARGS+=("-e" "TF_TOKEN_app_terraform_io=fake-tfe-token")
}

# Parse OPTINS and apply credential mounts; for non-granted opt-ins add tmpfs
# masks (mirrors run.sh's EPHEMERAL=0 block).
WITH_AWS=0
WITH_GLAB=0
WITH_TFE=0

if [ -n "${OPTINS}" ]; then
  old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086  # word-split on IFS is intentional for CSV parsing
  for optin in ${OPTINS}; do
    case "$optin" in
      aws)  WITH_AWS=1  ;;
      glab) WITH_GLAB=1 ;;
      tfe)  WITH_TFE=1  ;;
      *)    die "unknown opt-in: '$optin'" ;;
    esac
  done
  IFS="$old_ifs"
fi

[ "${WITH_AWS}"  = "1" ] && setup_fake_aws
[ "${WITH_GLAB}" = "1" ] && setup_fake_glab
[ "${WITH_TFE}"  = "1" ] && setup_fake_tfe

# ---------------------------------------------------------------------------
# Volume / ephemeral handling
# Mirror run.sh: when EPHEMERAL=0 mount named volumes + tmpfs masks for
# non-granted opt-ins.  When EPHEMERAL=1 skip named volumes entirely.
# ---------------------------------------------------------------------------
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
fi

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
    "${ENV_ARGS[@]}" \
    "${IMAGE}" \
    "${CONTAINER_ASSERT}" \
    2>"${CONTAINER_STDERR}" || rc=$?
  # Forward captured stderr to the terminal so CI logs are readable.
  cat "${CONTAINER_STDERR}" >&2 || true
  return "${rc:-0}"
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

CELL_DESC="uid=${HOST_UID_ARG} optins='${OPTINS}' volstate=${VOLSTATE} ro=${RO} ephemeral=${EPHEMERAL}"
log "Cell: ${CELL_DESC}"
log "Image: ${IMAGE}"

if [ "${VOLSTATE}" = "warm" ]; then
  # First run: cold — populates the named volume.
  log "Warm cell: running cold pass first..."
  run_container
  log "Warm cell: cold pass done; running warm pass..."
  run_container
else
  run_container
fi

# ---------------------------------------------------------------------------
# Host-side assertions
# ---------------------------------------------------------------------------

PROBE_FILE="${WORKSPACE_HOST}/smoke-probe.txt"

# 1 & 2. Probe file checks — skipped when RO=1 (workspace is :ro, container
#         cannot write to it; the RO cell tests entrypoint EROFS robustness only).
if [ "${RO}" = "0" ]; then
  # 1. The container wrote the probe file and it is non-empty.
  if [ ! -f "${PROBE_FILE}" ]; then
    die "host-side: probe file not created by container: ${PROBE_FILE}"
  fi
  if [ ! -s "${PROBE_FILE}" ]; then
    die "host-side: probe file is empty: ${PROBE_FILE}"
  fi
  log "host-side PASS: probe file exists and non-empty"

  # 2. Probe file owned by HOST_UID on the host. Bind mounts pass UIDs through
  #    numerically, so a file the container wrote as HOST_UID is owned by that
  #    same UID on the host — `stat` reads it back regardless of the runner's own
  #    UID (so this covers the uid=501 cell too). Skipped only for HOST_UID=0,
  #    where the file is root-owned and ownership round-trip is not the point.
  if [ "${HOST_UID_ARG}" != "0" ]; then
    PROBE_OWNER=$(stat -c '%u' "${PROBE_FILE}" 2>/dev/null || stat -f '%u' "${PROBE_FILE}" 2>/dev/null)
    if [ "${PROBE_OWNER}" = "${HOST_UID_ARG}" ]; then
      log "host-side PASS: probe file owned by ${HOST_UID_ARG}"
    else
      die "host-side: probe file owned by ${PROBE_OWNER}, expected ${HOST_UID_ARG}"
    fi
  fi
fi

# 3. RO robustness: no spurious 'entrypoint: WARN' on stderr.
if [ "${RO}" = "1" ]; then
  if grep -q 'entrypoint: WARN' "${CONTAINER_STDERR}" 2>/dev/null; then
    die "host-side (ro-robustness): unexpected 'entrypoint: WARN' on container stderr"
  fi
  log "host-side PASS (ro-robustness): no spurious entrypoint WARN on stderr"
fi

log "Cell PASS: ${CELL_DESC}"
