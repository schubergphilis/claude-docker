#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# smoke.sh — parameterized smoke-test driver for claude-docker. Each invocation
# exercises one cell of the test matrix by running the real run.sh, with the
# in-container assertions as the container command (CLAUDE_DOCKER_TEST_ENTRY).
#
# Parameters (flags or env vars):
#   --uid=N         HOST_UID to pass into the container (default: $(id -u))
#   --gid=N         HOST_GID to pass into the container (default: $(id -g))
#   --optins=CSV    comma-separated credential opt-ins: aws,glab,tfe,api,az (default: "")
#   --volstate=S    cold|warm — cold=fresh volume, warm=run twice reusing a volume
#   --ro=0|1        1 = pass --ro (workspace mounted :ro; robustness cell)
#   --ephemeral=0|1 1 = pass --ephemeral (no named volumes)
#   --settings=0|1  1 = give run.sh a settings.docker.json fixture to forward
#                   (entrypoint copies it to /root/.claude/settings.json);
#                   0 = no seed, asserts the entrypoint copes without one
#                   (default: 1). With --volstate=warm, the warm pass reruns
#                   against a rewritten fixture (V2 sentinel) to prove the
#                   entrypoint re-seeds, then a final no-seed pass proves a
#                   persisted settings.json is left as-is.
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
# run.sh mounts each workspace at /workspaces/<basename>, so the dir is named
# "smoke" to land at the path assert-in-container.sh expects.
WORKSPACE_HOST="${TMPROOT}/smoke"
# run.sh reads host credentials and Claude config from $HOME; point it at a
# fake home so a cell only ever sees the fixtures below, never the real ones.
FAKE_HOME="${TMPROOT}/home"
SHIM_DIR="${TMPROOT}/bin"
mkdir -p "${WORKSPACE_HOST}" "${FAKE_HOME}/.claude" "${SHIM_DIR}"
# Make the workspace world-writable so a container running as a synthetic
# HOST_UID (e.g. 501) that differs from the CI runner's UID can write into it —
# in production the workspace is the user's own repo, owned by HOST_UID and
# writable. Without this, the runner-owned (0755) dir blocks the non-runner UID
# cells. Files the container creates are owned by HOST_UID; the host-side
# ownership assertion below only runs when HOST_UID matches the runner so it
# can read that ownership back.
chmod 0777 "${WORKSPACE_HOST}"

# Per-cell named volumes, substituted for run.sh's claude-code-root/-home by
# the docker shim below. Empty for --ephemeral (run.sh mounts none).
VOL_NAME=""
[ "${EPHEMERAL}" = "0" ] && VOL_NAME="smoke-test-$$"
CONTAINER_STDERR="${TMPROOT}/container_stderr.txt"

cleanup() {
  if [ -n "${VOL_NAME}" ]; then
    docker volume rm "${VOL_NAME}-root" >/dev/null 2>&1 || true
    docker volume rm "${VOL_NAME}-home" >/dev/null 2>&1 || true
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
RUN_SH="$(cd "${SCRIPT_DIR}/.." && pwd)/run.sh"
[ -f "${ASSERT_SCRIPT}" ] || die "assert-in-container.sh not found at: ${ASSERT_SCRIPT}"
[ -f "${RUN_SH}" ] || die "run.sh not found at: ${RUN_SH}"
cp "${ASSERT_SCRIPT}" "${WORKSPACE_HOST}/assert-in-container.sh"
chmod +x "${WORKSPACE_HOST}/assert-in-container.sh"

# ---------------------------------------------------------------------------
# docker shim. The cell drives the real run.sh, so every security flag, mount
# and tmpfs mask on the agent `docker run` is run.sh's own. The shim rewrites
# only what a cell must control and run.sh does not expose:
#   - HOST_UID / HOST_GID (run.sh always passes the caller's `id -u/-g`)
#   - the named volumes, so a cell never touches the user's real
#     claude-code-root / claude-code-home and every cell starts cold
#   - `-it`, since CI has no TTY
# It fails closed if run.sh's invocation no longer carries those args, so a
# rename in run.sh cannot silently point a cell at the real volumes.
# ---------------------------------------------------------------------------
SMOKE_REAL_DOCKER=$(command -v docker) || die "docker not found on PATH"
export SMOKE_REAL_DOCKER HOST_UID_ARG HOST_GID_ARG VOL_NAME
cat > "${SHIM_DIR}/docker" <<'SHIM'
#!/usr/bin/env bash
[ "${1:-}" = "run" ] || exec "$SMOKE_REAL_DOCKER" "$@"
args=()
ids=0
vols=0
for a in "$@"; do
  case "$a" in
    -it) continue ;;
    HOST_UID=*) a="HOST_UID=$HOST_UID_ARG"; ids=$((ids + 1)) ;;
    HOST_GID=*) a="HOST_GID=$HOST_GID_ARG"; ids=$((ids + 1)) ;;
    claude-code-root:/root) a="$VOL_NAME-root:/root"; vols=$((vols + 1)) ;;
    claude-code-home:/root/.claude) a="$VOL_NAME-home:/root/.claude"; vols=$((vols + 1)) ;;
  esac
  args+=("$a")
done
want_vols=2
[ -z "$VOL_NAME" ] && want_vols=0
if [ "$ids" != 2 ] || [ "$vols" != "$want_vols" ]; then
  echo "[smoke] FAIL: docker shim: run.sh's docker run no longer matches (HOST_UID/GID rewrites=$ids, volume rewrites=$vols, want 2/$want_vols) — update the shim in smoke.sh" >&2
  exit 1
fi
exec "$SMOKE_REAL_DOCKER" "${args[@]}"
SHIM
chmod +x "${SHIM_DIR}/docker"

# ---------------------------------------------------------------------------
# run.sh flags + fixtures
# ---------------------------------------------------------------------------
RUN_FLAGS=()
[ "${RO}" = "1" ] && RUN_FLAGS+=("--ro")
[ "${EPHEMERAL}" = "1" ] && RUN_FLAGS+=("--ephemeral")
OPTIN_ENV=()

# Settings fixture — the host-side settings.docker.json run.sh forwards to the
# seed path; the entrypoint copies it to /root/.claude/settings.json.
# The sentinel proves the seeded copy came from OUR fixture; the in-container
# check also renames a tmp file over the copy — the regression that motivated
# the seed-copy design (rename() over a single-file bind mount → EBUSY).
# The fixture and these two are mutable across warm-cell passes (see the warm
# branch below), so run_container reads the current values.
SETTINGS_FIXTURE="${FAKE_HOME}/.claude/settings.docker.json"
SETTINGS_SENTINEL="SMOKE-SENTINEL-SETTINGS"
EXPECT_SETTINGS_MODE="${SETTINGS}"
if [ "${SETTINGS}" = "1" ]; then
  printf '{"env":{"SMOKE_SENTINEL":"%s"}}\n' "${SETTINGS_SENTINEL}" > "${SETTINGS_FIXTURE}"
fi

# Fake credentials at the host paths run.sh reads, under the fake $HOME.
# Each fake cred embeds the literal SMOKE-SENTINEL string. The in-container
# assertion greps the mounted path for it, proving the EXPECTED fixture was
# mounted (not some other host file a regression might bind in its place).
setup_fake_aws() {
  mkdir -p "${FAKE_HOME}/.aws/sso"
  printf '[default]\nregion = us-east-1\n# SMOKE-SENTINEL-AWS\n' > "${FAKE_HOME}/.aws/config"
  RUN_FLAGS+=("--aws")
  OPTIN_ENV+=("AWS_PROFILE=default")
}

setup_fake_glab() {
  mkdir -p "${FAKE_HOME}/.config/glab-cli"
  printf 'token = SMOKE-SENTINEL-GLAB\n' > "${FAKE_HOME}/.config/glab-cli/config.yml"
  RUN_FLAGS+=("--glab")
  OPTIN_ENV+=("GITLAB_TOKEN=fake-gitlab-token")
}

setup_fake_tfe() {
  mkdir -p "${FAKE_HOME}/.terraform.d"
  printf '{"credentials":{"app.terraform.io":{"token":"SMOKE-SENTINEL-TFE"}}}\n' \
    > "${FAKE_HOME}/.terraform.d/credentials.tfrc.json"
  RUN_FLAGS+=("--tfe")
  OPTIN_ENV+=("TF_TOKEN_app_terraform_io=fake-tfe-token")
}

# --api: a throwaway self-signed CA handed to run.sh as CLAUDE_DOCKER_API_CA,
# so the entrypoint's update-ca-certificates step is exercised.
setup_fake_api() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj "/CN=claude-docker smoke CA" \
    -keyout "${FAKE_HOME}/api-ca.key" -out "${FAKE_HOME}/api-ca.crt" >/dev/null 2>&1 \
    || die "openssl could not generate the --api smoke CA"
  chmod 0644 "${FAKE_HOME}/api-ca.crt"
  RUN_FLAGS+=("--api")
  OPTIN_ENV+=("ANTHROPIC_BASE_URL=https://llm.smoke.invalid" "CLAUDE_DOCKER_API_CA=${FAKE_HOME}/api-ca.crt")
}

setup_fake_az() {
  mkdir -p "${FAKE_HOME}/.azure"
  printf '{"installationId": "SMOKE-SENTINEL-AZ", "subscriptions": []}\n' > "${FAKE_HOME}/.azure/azureProfile.json"
  RUN_FLAGS+=("--az")
  OPTIN_ENV+=("AZURE_DEVOPS_EXT_PAT=fake-azdo-pat")
}

if [ -n "${OPTINS}" ]; then
  old_ifs="$IFS"
  IFS=','
  # shellcheck disable=SC2086  # word-split on IFS is intentional for CSV parsing
  for optin in ${OPTINS}; do
    case "$optin" in
      aws)  setup_fake_aws  ;;
      glab) setup_fake_glab ;;
      tfe)  setup_fake_tfe  ;;
      api)  setup_fake_api  ;;
      az)   setup_fake_az   ;;
      *)    die "unknown opt-in: '$optin'" ;;
    esac
  done
  IFS="$old_ifs"
fi

# ---------------------------------------------------------------------------
# Single-run helper
# ---------------------------------------------------------------------------
run_container() {
  # Expectations reach the assert script through CLAUDE_DOCKER_TEST_ENTRY (the
  # command run.sh runs in place of claude), since run.sh forwards no
  # arbitrary env. Values are digits, validated opt-in names and sentinels.
  local entry rc
  entry="export EXPECT_UID=${HOST_UID_ARG} EXPECT_GID=${HOST_GID_ARG} EXPECT_OPTINS=${OPTINS}"
  entry+=" EXPECT_RO=${RO} EXPECT_EPHEMERAL=${EPHEMERAL} WORKSPACE=/workspaces/smoke"
  entry+=" EXPECT_SETTINGS=${EXPECT_SETTINGS_MODE} EXPECT_SETTINGS_SENTINEL=${SETTINGS_SENTINEL};"
  entry+=" exec /workspaces/smoke/assert-in-container.sh"
  # Capture stderr to a file for the host-side WARN assertion, and also
  # forward it to the terminal so CI logs show container output.
  # "${arr[@]+"${arr[@]}"}" is the set -u-safe empty-array expansion idiom
  # (bash 3.2 on macOS errors on a plain empty "${arr[@]}").
  env -u CLAUDE_DOCKER_TMUX -u CLAUDE_DOCKER_CONFIG_DIR \
    HOME="${FAKE_HOME}" PATH="${SHIM_DIR}:${PATH}" \
    CLAUDE_DOCKER_RUNTIME=docker CLAUDE_DOCKER_IMAGE="${IMAGE}" \
    CLAUDE_DOCKER_TEST_ENTRY="${entry}" \
    "${OPTIN_ENV[@]+"${OPTIN_ENV[@]}"}" \
    bash "${RUN_SH}" "${RUN_FLAGS[@]+"${RUN_FLAGS[@]}"}" "${WORKSPACE_HOST}" \
    </dev/null 2>"${CONTAINER_STDERR}" || rc=$?
  # Forward captured stderr to the terminal so CI logs are readable.
  cat "${CONTAINER_STDERR}" >&2 || true
  return "${rc:-0}"
}

# ---------------------------------------------------------------------------
# Execute
# ---------------------------------------------------------------------------

CELL_DESC="uid=${HOST_UID_ARG} gid=${HOST_GID_ARG} optins='${OPTINS}' volstate=${VOLSTATE} ro=${RO} ephemeral=${EPHEMERAL} settings=${SETTINGS}"
log "Cell: ${CELL_DESC}"
log "Image: ${IMAGE}"

if [ "${VOLSTATE}" = "warm" ]; then
  # First run: cold — populates the named volume.
  log "Warm cell: running cold pass first..."
  run_container
  if [ "${SETTINGS}" = "1" ]; then
    # Rewrite the fixture with a second sentinel. The warm pass must find V2,
    # proving the entrypoint RE-SEEDED — overwrote the copy pass 1 left in the
    # volume — which is the spec's "next container start re-seeds
    # settings.json from the host file" contract. Rerunning with the same
    # content would let a `[ -f ] || cp` re-implementation pass on pass 1's
    # leftovers.
    SETTINGS_SENTINEL="SMOKE-SENTINEL-SETTINGS-V2"
    printf '{"env":{"SMOKE_SENTINEL":"%s"}}\n' "${SETTINGS_SENTINEL}" > "${SETTINGS_FIXTURE}"
  fi
  log "Warm cell: cold pass done; running warm pass..."
  run_container
  if [ "${SETTINGS}" = "1" ]; then
    # Final pass with NO seed on the host: a warm volume holding a previously
    # persisted settings.json must be left as-is (spec: "No settings file" —
    # "whatever a previous run persisted in the home volume"). The V2
    # sentinel from the warm pass must survive untouched.
    rm -f "${SETTINGS_FIXTURE}"
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
#    (--aws/--glab/--tfe/--az), so the opt-in cells are what actually pin the
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
