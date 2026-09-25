#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# smoke.sh — parameterized smoke-test driver for the claude-docker entrypoint.
# Each invocation exercises one cell of the test matrix.
#
# Parameters (flags or env vars):
#   --uid=N         HOST_UID to pass into the container (default: $(id -u))
#   --gid=N         HOST_GID to pass into the container (default: $(id -g))
#   --optins=CSV    comma-separated credential opt-ins: aws,glab,tfe (default: "")
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
#   --egress=0|1    1 = drive run.sh --egress-allowlist end-to-end instead of a
#                   hand-built `docker run` (the boundary lives in run.sh's
#                   network/sidecar lifecycle, so it must be exercised through
#                   it). Three passes over the same project allowlist
#                   (example.com): answer `n` at the approval prompt (list
#                   ignored), answer `y` (list used, hash recorded), then no
#                   input (recorded approval honoured). Runner UID only;
#                   implies ephemeral, no opt-ins, no settings seed.
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
SETTINGS="1"
EGRESS="0"
IMAGE="${IMAGE:-claude-code:local}"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
HOST_GID_ARG="${HOST_GID:-$(id -g)}"
for arg in "$@"; do
  case "$arg" in
    --uid=*)       HOST_UID_ARG="${arg#--uid=}" ;;
    --gid=*)       HOST_GID_ARG="${arg#--gid=}" ;;
    --optins=*)    OPTINS="${arg#--optins=}" ;;
    --volstate=*)  VOLSTATE="${arg#--volstate=}" ;;
    --ro=*)        RO="${arg#--ro=}" ;;
    --ephemeral=*) EPHEMERAL="${arg#--ephemeral=}" ;;
    --settings=*)  SETTINGS="${arg#--settings=}" ;;
    --egress=*)    EGRESS="${arg#--egress=}" ;;
    --image=*)     IMAGE="${arg#--image=}" ;;
    *) echo "smoke.sh: unknown argument '$arg'" >&2; exit 1 ;;
  esac
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo "[smoke] $*"; }

die() { echo "[smoke] FAIL: $*" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Temp workspace + cleanup
# ---------------------------------------------------------------------------
# Staged under $HOME, not the mktemp default: everything under TMPROOT is
# bind-mounted into containers, and macOS docker VMs don't share the default
# location (Colima shares only $HOME; /var/folders is invisible to it), so
# sources there arrive as empty dirs in-container. macOS mktemp ignores even
# an explicit TMPDIR override for no-template invocations, hence the explicit
# template. Same rationale as run.sh's stage_root.
smoke_stage_root="${HOME}/.cache/claude-docker"
mkdir -p "${smoke_stage_root}"
TMPROOT=$(mktemp -d "${smoke_stage_root}/smoke.XXXXXX")
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
# Resolve this script's dir portably — `realpath` is GNU coreutils and is not
# on stock macOS (where the Phase 2b job runs smoke.sh on the host directly).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ASSERT_SCRIPT="${SCRIPT_DIR}/assert-in-container.sh"
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
WS_SUFFIX=""
[ "${RO}" = "1" ] && WS_SUFFIX=":ro"
MOUNT_ARGS=(
  "-v" "${WORKSPACE_HOST}:${CONTAINER_WORKSPACE}${WS_SUFFIX}"
)

# Settings fixture — mirrors run.sh's settings.docker.json forwarding: mounted
# :ro at the seed path, entrypoint copies it to /root/.claude/settings.json.
# The sentinel proves the seeded copy came from OUR fixture; the in-container
# check also renames a tmp file over the copy — the regression that motivated
# the seed-copy design (rename() over a single-file bind mount → EBUSY).
# These three are mutable across warm-cell passes (see the warm branch below),
# so the mount lives in its own array and run_container reads the current
# values instead of baking them into ENV_ARGS.
SETTINGS_FIXTURE="${TMPROOT}/settings.docker.json"
SETTINGS_SENTINEL="SMOKE-SENTINEL-SETTINGS"
EXPECT_SETTINGS_MODE="${SETTINGS}"
SETTINGS_MOUNT_ARGS=()
if [ "${SETTINGS}" = "1" ]; then
  printf '{"env":{"SMOKE_SENTINEL":"%s"}}\n' "${SETTINGS_SENTINEL}" > "${SETTINGS_FIXTURE}"
  SETTINGS_MOUNT_ARGS=(
    "-v" "${SETTINGS_FIXTURE}:/run/claude-docker/settings.json:ro"
  )
fi

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
  # AWS is masked in both directions, only the scope changes (see run.sh).
  # tests/test_masks.py asserts this mirror stays in step with run.sh — the
  # mirror is why a mask missing from run.sh cannot fail this suite on its own.
  if [ "${WITH_AWS}" = "0" ]; then
    VOLUME_ARGS+=("--tmpfs" "/root/.aws")
  else
    VOLUME_ARGS+=("--tmpfs" "/root/.aws/cli/cache")
  fi
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
# Execute
# ---------------------------------------------------------------------------

CELL_DESC="uid=${HOST_UID_ARG} gid=${HOST_GID_ARG} optins='${OPTINS}' volstate=${VOLSTATE} ro=${RO} ephemeral=${EPHEMERAL} settings=${SETTINGS} egress=${EGRESS}"
log "Cell: ${CELL_DESC}"
log "Image: ${IMAGE}"

# One run.sh --egress-allowlist pass. $1 = line typed at the approval prompt
# (empty = no input), $2 = EXPECT_EGRESS_PROJECT. run.sh's `docker run -it`
# needs a PTY, hence script(1); its transcript lands in CONTAINER_STDERR so
# the host-side WARN check below still applies.
run_egress_pass() {
  local answer="$1" expect_project="$2" rc=0 entry run_cmd
  entry="env EXPECT_EGRESS=1 EXPECT_EGRESS_PROJECT=${expect_project} EXPECT_UID=${HOST_UID_ARG} EXPECT_GID=${HOST_GID_ARG} EXPECT_OPTINS= EXPECT_RO=0 EXPECT_EPHEMERAL=1 EXPECT_SETTINGS=0 WORKSPACE=${CONTAINER_WORKSPACE} ${CONTAINER_ASSERT}"
  run_cmd="bash $(printf '%q' "${SCRIPT_DIR}/../run.sh") --ephemeral --egress-allowlist $(printf '%q' "${WORKSPACE_HOST}")"
  { [ -n "${answer}" ] && printf '%s\n' "${answer}"; true; } \
    | CLAUDE_DOCKER_IMAGE="${IMAGE}" CLAUDE_DOCKER_TEST_ENTRY="${entry}" \
      CLAUDE_DOCKER_CONFIG_DIR="${TMPROOT}/no-claude-dir" XDG_CONFIG_HOME="${TMPROOT}/xdg" \
      SHELL=/bin/bash timeout -k 10 300 script -qec "${run_cmd}" "${CONTAINER_STDERR}" \
      >/dev/null 2>&1 || rc=$?
  tr -d '\r' <"${CONTAINER_STDERR}" >&2 || true
  return "${rc}"
}

if [ "${EGRESS}" = "1" ]; then
  [ "${HOST_UID_ARG}" = "$(id -u)" ] || die "--egress=1 runs run.sh, which always uses the runner UID"
  command -v script >/dev/null 2>&1 || die "--egress=1 needs script(1) for run.sh's PTY"
  CONTAINER_WORKSPACE="/workspaces/$(basename "${WORKSPACE_HOST}")"
  CONTAINER_ASSERT="${CONTAINER_WORKSPACE}/assert-in-container.sh"
  mkdir -p "${WORKSPACE_HOST}/.claude-docker"
  printf '# smoke fixture\nexample.com\n' >"${WORKSPACE_HOST}/.claude-docker/allowed-hosts"

  log "Egress pass 1: decline the project list"
  run_egress_pass n 0 || die "egress pass 1 (declined project list) failed"
  grep -q 'is not approved' "${CONTAINER_STDERR}" \
    || die "host-side: no 'not approved' warning for a declined project list"
  grep -q '^ *example\.org' "${CONTAINER_STDERR}" \
    || die "host-side: exit summary does not list the denied example.org"
  log "host-side PASS: declined list warned; denied host listed at exit"

  log "Egress pass 2: approve the project list"
  run_egress_pass y 1 || die "egress pass 2 (approved project list) failed"
  [ -s "${TMPROOT}/xdg/claude-docker/egress-approved" ] \
    || die "host-side: approval was not recorded"

  log "Egress pass 3: recorded approval, no prompt input"
  run_egress_pass "" 1 || die "egress pass 3 (recorded approval) failed"

  if docker ps -a --format '{{.Names}}' | grep -q '^claude-egress-proxy-' \
     || docker network ls --format '{{.Name}}' | grep -q '^claude-egress-'; then
    die "host-side: claude-egress-* resources left behind after teardown"
  fi
  log "host-side PASS: no claude-egress-* resources left behind"
elif [ "${VOLSTATE}" = "warm" ]; then
  # First run: cold — populates the named volume.
  log "Warm cell: running cold pass first..."
  run_container
  if [ "${SETTINGS}" = "1" ]; then
    # Rewrite the fixture IN PLACE with a second sentinel (truncate keeps the
    # inode, so the :ro bind mount sees the new content). The warm pass must
    # find V2, proving the entrypoint RE-SEEDED — overwrote the copy pass 1
    # left in the volume — which is the spec's "next container start re-seeds
    # settings.json from the host file" contract. Rerunning with the same
    # content would let a `[ -f ] || cp` re-implementation pass on pass 1's
    # leftovers.
    SETTINGS_SENTINEL="SMOKE-SENTINEL-SETTINGS-V2"
    printf '{"env":{"SMOKE_SENTINEL":"%s"}}\n' "${SETTINGS_SENTINEL}" > "${SETTINGS_FIXTURE}"
  fi
  log "Warm cell: cold pass done; running warm pass..."
  run_container
  if [ "${SETTINGS}" = "1" ]; then
    # Final pass with NO seed mounted: a warm volume holding a previously
    # persisted settings.json must be left as-is (spec: "No settings file" —
    # "whatever a previous run persisted in the home volume"). The V2
    # sentinel from the warm pass must survive untouched.
    SETTINGS_MOUNT_ARGS=()
    EXPECT_SETTINGS_MODE="keep"
    log "Warm cell: warm pass done; running no-seed pass (persisted settings kept)..."
    run_container
  fi
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

log "Cell PASS: ${CELL_DESC}"
