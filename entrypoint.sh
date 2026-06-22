#!/usr/bin/env bash
# Drop from container root to the host user's UID/GID before exec'ing claude
# so that files written through bind-mounts match host ownership. With
# HOST_UID unset or 0, falls through to the legacy "run as root" behavior so
# the image still works in environments that don't forward the host UID.
set -euo pipefail

HOST_UID="${HOST_UID:-0}"
HOST_GID="${HOST_GID:-0}"

if [ "$HOST_UID" = 0 ]; then
exec "$@"
fi

# Synthesize a passwd entry so getpwuid / $HOME / shell expansions resolve
# cleanly inside the container. -o (--non-unique) tolerates a HOST_UID that
# happens to collide with a baked-in Ubuntu system user. HOME=/root is
# deliberate — keeps the existing /root/.claude, /root/.aws, /root/.config
# mount paths intact instead of forcing a layout migration.
# -K UID_MIN=1 overrides the login.defs floor per-call so macOS UIDs (≥501,
# below Ubuntu's default 1000) don't trigger a warning.
if ! getent passwd "$HOST_UID" >/dev/null 2>&1; then
getent group "$HOST_GID" >/dev/null 2>&1 \
    || groupadd -o -g "$HOST_GID" claude
useradd -o -K UID_MIN=1 -u "$HOST_UID" -g "$HOST_GID" -d /root -s /bin/bash -M -N claude
fi

# Chown the persistent /root volumes (claude-code-root, claude-code-home)
# so the dropped-privilege user can write its own HOME. -xdev prunes the
# :ro credential and config bind-mounts under /root on Linux (they have
# distinct st_dev), but Docker Desktop's virtiofs on macOS collapses
# st_dev across bind mounts so the walk descends into them anyway. chown
# on a :ro mount returns EROFS, which would abort the entrypoint under
# set -e — so we capture stderr, drop the expected EROFS lines, and
# surface anything else as a warning. Pruning by /proc/self/mountinfo
# would also skip the *writable* tmpfs masks (which we do want to chown),
# so the post-hoc filter is the simpler-correct option. Two start points
# because /root and /root/.claude are separate volumes. Requires
# CAP_CHOWN to chown to a different UID, and CAP_DAC_READ_SEARCH so
# container root can traverse HOST_UID-owned, mode-0700 directories
# under /root.
chown_errs="$(find /root /root/.claude -xdev -print0 \
  | xargs -0 --no-run-if-empty chown -h "$HOST_UID:$HOST_GID" 2>&1 >/dev/null || true)"
chown_errs="$(grep -v 'Read-only file system' <<<"$chown_errs" || true)"
[ -n "$chown_errs" ] && printf 'entrypoint: WARN chown: %s\n' "$chown_errs" >&2 || true

# runuser uses setresuid()/setresgid() — needs CAP_SETUID and CAP_SETGID
# at this point (we're still UID 0). The kernel clears effective,
# permitted, and ambient caps on the UID→non-zero transition; the bounding
# set retains the setup caps but is inert under `no-new-privileges`. So
# claude itself runs with no usable capabilities downstream — a stricter
# posture than the previous "root + DAC_OVERRIDE for the entire session"
# model where claude held DAC_OVERRIDE for its whole lifetime.
exec runuser -u claude -- "$@"
