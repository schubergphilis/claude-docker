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
if ! getent passwd "$HOST_UID" >/dev/null 2>&1; then
getent group "$HOST_GID" >/dev/null 2>&1 \
    || groupadd -o -g "$HOST_GID" claude
useradd -o -u "$HOST_UID" -g "$HOST_GID" -d /root -s /bin/bash -M -N claude
fi

# Chown the persistent /root volumes (claude-code-root, claude-code-home) so
# the dropped-privilege user can write its own HOME. -xdev stops at each
# nested mount — critical so we don't try to chown the :ro credential and
# config bind-mounts that sit under /root (chown on a ro mount returns
# EROFS, which would abort the entrypoint under set -e; EROFS fires before
# any same-owner short-circuit, so we can't rely on that either). Two
# start points because /root and /root/.claude are separate volumes — a
# single -xdev walk would cover only one. Requires CAP_CHOWN to chown to
# a different UID, and CAP_DAC_READ_SEARCH on warm runs to traverse
# directories now owned by HOST_UID with mode 0700.
find /root /root/.claude -xdev -print0 \
  | xargs -0 --no-run-if-empty chown -h "$HOST_UID:$HOST_GID"

# runuser uses setresuid()/setresgid() — needs CAP_SETUID and CAP_SETGID
# at this point (we're still UID 0). The kernel clears effective,
# permitted, and ambient caps on the UID→non-zero transition; the bounding
# set retains the setup caps but is inert under `no-new-privileges`. So
# claude itself runs with no usable capabilities downstream — a stricter
# posture than the previous "root + DAC_OVERRIDE for the entire session"
# model where claude held DAC_OVERRIDE for its whole lifetime.
exec runuser -u claude -- "$@"
