#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# Drop from container root to the host user's UID/GID before exec'ing claude
# so that files written through bind-mounts match host ownership. With
# HOST_UID unset or 0, falls through to the legacy "run as root" behavior so
# the image still works in environments that don't forward the host UID.

# Fixed paths. Plain globals, not env, so the container environment can't
# redirect them; the BATS suite reassigns them after sourcing.
SEED_SETTINGS=/run/claude-docker/settings.json
ROOT_HOME=/root
CA_DIR=/usr/local/share/ca-certificates

# Seed /root/.claude/settings.json from the host settings.docker.json that
# run.sh forwards at the seed path. A copy, not a bind mount at the real path:
# Claude Code persists settings by renaming a tmp file over settings.json, and
# rename() over a mountpoint fails with EBUSY — a direct single-file mount
# breaks every in-session settings change. The copy lives on the container
# filesystem, so those writes work; they last for this run only and are
# overwritten from the host file on the next start.
# Ownership dance: on a warm volume the dir/file are HOST_UID-owned from a
# prior run's chown walk, and container root has no CAP_DAC_OVERRIDE — take
# ownership (CAP_CHOWN) before writing; the chown walk below hands everything
# back to HOST_UID. rm+cp instead of cp -f for the same reason: overwriting a
# HOST_UID-owned 0600 file in place would be denied.
seed_settings() {
  [ -f "$SEED_SETTINGS" ] || return 0
  mkdir -p "$ROOT_HOME/.claude" || return
  chown root "$ROOT_HOME/.claude" || return
  rm -f "$ROOT_HOME/.claude/settings.json" || return
  cp "$SEED_SETTINGS" "$ROOT_HOME/.claude/settings.json" || return
  chmod 600 "$ROOT_HOME/.claude/settings.json"
}

# GitHub auth-proxy sidecar CA (run.sh --gh with a sidecar active): install
# it into the system trust store so git (libcurl) and gh (Go) trust the
# sidecar's TLS termination for the redirected GitHub hostnames. Must run
# as root, before the UID drop below — update-ca-certificates writes under
# /etc/ssl/certs. Silent when the file is absent (no --gh, --gh-direct, or
# the no-token fallback); a refresh failure is a warning, not fatal, so it
# doesn't block the session over a CA problem the user can't fix here.
# The same step installs the --api private CA (CLAUDE_DOCKER_API_CA), which
# Claude Code's native binary then trusts via the OS store.
install_cas() {
  compgen -G "$CA_DIR/claude-docker-*.crt" >/dev/null || return 0
  update-ca-certificates >/dev/null 2>&1 \
    || printf 'entrypoint: WARN update-ca-certificates failed for a claude-docker CA\n' >&2
}

# --egress-lock with ANTHROPIC_API_KEY: approve the key in ~/.claude.json the
# way Claude Code's own "use this API key?" prompt does (its last 20
# characters in customApiKeyResponses.approved). Until it is approved, Claude
# Code treats claude.ai login as possible, and onboarding then starts with a
# connectivity check against api.anthropic.com and platform.claude.com — hosts
# the lock refuses, so the session exits before the prompt is reached. That
# happens on every fresh claude-code-root volume and every --ephemeral run.
# ANTHROPIC_AUTH_TOKEN needs no approval and skips the check by itself.
# The key comes from the environment, not argv, so it never shows in ps. The
# file is opened once and only used if that open didn't follow a symlink: a
# concurrent session's agent shares the volume and could swap one in. Invalid
# JSON is left alone. A new file replaces the old by rename; the chown walk
# below hands it back to HOST_UID.
approve_api_key() {
  [ "${CLAUDE_DOCKER_EGRESS_LOCK:-}" = 1 ] && [ -n "${ANTHROPIC_API_KEY:-}" ] || return 0
  local cfg="$ROOT_HOME/.claude.json" cfg_tmp rc
  if [ -e "$cfg" ] || [ -L "$cfg" ]; then
    if ! exec 3<"$cfg" || [ "$(readlink /proc/self/fd/3)" != "$cfg" ]; then
      exec 3<&-
      printf 'entrypoint: WARN %s is not a regular file; not approving ANTHROPIC_API_KEY\n' "$cfg" >&2
      return 0
    fi
  else
    exec 3<<<'{}'
  fi
  # Every early return closes fd 3, and one after mktemp removes the temp file:
  # it sits in the persistent volume.
  chown root "$ROOT_HOME" || { rc=$?; exec 3<&-; return "$rc"; }
  cfg_tmp=$(mktemp "$cfg.XXXXXX") || { rc=$?; exec 3<&-; return "$rc"; }
  if jq '(env.ANTHROPIC_API_KEY | gsub("^\\s+|\\s+$"; "") | .[-20:]) as $id
         | .customApiKeyResponses.rejected //= []
         | .customApiKeyResponses.approved //= []
         | if (.customApiKeyResponses.approved | index([$id])) then .
           else .customApiKeyResponses.approved += [$id] end' <&3 >"$cfg_tmp" 2>/dev/null; then
    mv -f "$cfg_tmp" "$cfg" || { rc=$?; rm -f "$cfg_tmp"; exec 3<&-; return "$rc"; }
  else
    rm -f "$cfg_tmp"
    printf 'entrypoint: WARN %s is not valid JSON; not approving ANTHROPIC_API_KEY\n' "$cfg" >&2
  fi
  exec 3<&-
}

# Synthesize a passwd entry so getpwuid / $HOME / shell expansions resolve
# cleanly inside the container. Guarded on the `claude` name, not on
# HOST_UID: a HOST_UID that collides with a baked-in Ubuntu system user
# still needs a `claude` entry for `runuser -u claude`, and -o
# (--non-unique) lets useradd create it with the duplicate UID. HOME=/root
# is deliberate — keeps the existing /root/.claude, /root/.aws, /root/.config
# mount paths intact instead of forcing a layout migration.
# -K UID_MIN=1 overrides the login.defs floor per-call so macOS UIDs (≥501,
# below Ubuntu's default 1000) don't trigger a warning.
# An existing `claude` (e.g. one a child image added) must already have
# HOST_UID: otherwise the session would run as that UID — wrong owner on the
# workspace mounts, and no privilege drop at all if it is 0 — so refuse.
ensure_user() {
  local uid=$1 gid=$2 existing
  if getent passwd claude >/dev/null 2>&1; then
    existing="$(id -u claude)" || return
    [ "$existing" = "$uid" ] && return 0
    printf 'entrypoint: ERROR existing claude user has UID %s, expected HOST_UID %s\n' \
      "$existing" "$uid" >&2
    return 1
  fi
  getent group "$gid" >/dev/null 2>&1 \
    || groupadd -o -g "$gid" claude \
    || return
  useradd -o -K UID_MIN=1 -u "$uid" -g "$gid" -d /root -s /bin/bash -M -N claude
}

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
# under /root. stderr is captured for the whole pipeline, so a failing
# find warns too; LC_ALL=C pins the EROFS message the filter matches.
chown_volumes() {
  local uid=$1 gid=$2 chown_errs roots=("$ROOT_HOME")
  # /root/.claude is its own volume, absent under --ephemeral until something
  # (a seeded settings.json) creates it.
  [ -d "$ROOT_HOME/.claude" ] && roots+=("$ROOT_HOME/.claude")
  chown_errs="$( { find "${roots[@]}" -xdev -print0 \
    | xargs -0 --no-run-if-empty chown -h "$uid:$gid"; } 2>&1 >/dev/null || true)"
  chown_errs="$(grep -v 'Read-only file system' <<<"$chown_errs" || true)"
  if [ -n "$chown_errs" ]; then
    printf 'entrypoint: WARN chown: %s\n' "$chown_errs" >&2
  fi
}

main() {
  set -euo pipefail
  local uid="${HOST_UID:-0}" gid="${HOST_GID:-0}"
  # Explicit || return on every step: set -e is ignored when main runs in
  # an ||/if context or under bats `run`, and a failed step must not
  # fall through to the exec.
  seed_settings || return
  install_cas || return
  approve_api_key || return
  if [ "$uid" = 0 ]; then
    exec "$@"
  fi
  ensure_user "$uid" "$gid" || return
  # Scoped to the walk: the session itself keeps the caller's locale.
  LC_ALL=C chown_volumes "$uid" "$gid" || return
  # runuser uses setresuid()/setresgid() — needs CAP_SETUID and CAP_SETGID
  # at this point (we're still UID 0). The kernel clears effective,
  # permitted, and ambient caps on the UID→non-zero transition; the bounding
  # set retains the setup caps but is inert under `no-new-privileges`. So
  # claude itself runs with no usable capabilities downstream — a stricter
  # posture than the previous "root + DAC_OVERRIDE for the entire session"
  # model where claude held DAC_OVERRIDE for its whole lifetime.
  exec runuser -u claude -- "$@"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
