#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
set -euo pipefail

# Override via CLAUDE_DOCKER_IMAGE so child images (FROM claude-code:local) can
# reuse this wrapper's full feature set — credential opt-ins, statusline tag,
# git-identity forwarding, host-config bind-mounts — without forking it.
IMAGE="${CLAUDE_DOCKER_IMAGE:-claude-code:local}"

# GitHub auth-proxy sidecar image (Caddy), used only by --gh when a host
# token is found (see gh-auth-proxy-sidecar). Digest-pinned and deliberately
# excluded from update_pins.py: a Caddy upgrade can change Caddyfile
# directive semantics — i.e. this security-critical config — so bumping it
# is a reviewed change (changelog + config-compatibility check), not a
# routine automated bump. run.sh cannot read pins/, so the pin lives here.
PROXY_IMAGE="${CLAUDE_DOCKER_PROXY_IMAGE:-caddy:2.11.4@sha256:844f60b64e4724a5aa8245e019dace0d3f199f7433ce6c57676cb30a920dbad9}"

# Keep this in sync with the flag-parsing case statement below — adding or
# removing a wrapper flag means updating both the case branch and this heredoc
# in the same diff.
print_help() {
  cat <<'EOF'
Usage: claude-docker [OPTIONS] [WORKSPACE...] [-- CLAUDE_FLAGS...]

Hardened Docker wrapper for Claude Code. Wrapper flags and workspace paths
are parsed before `--`; anything after `--` is forwarded verbatim to the
`claude` binary inside the container.

Workspaces:
  WORKSPACE...        One or more host directories to mount at
                      /workspaces/<basename>. Defaults to $PWD when omitted.
                      First workspace becomes the container's working dir;
                      every additional workspace is passed to claude as
                      --add-dir so the agent can read/write across all of them.

Wrapper flags:
  -h, --help          Print this help and exit 0 without starting Docker.
  --yolo              Pass --dangerously-skip-permissions to claude.
  --ephemeral         Skip the claude-code-root/claude-code-home named
                      volumes. No OAuth token, gh login, shell history, or
                      session history persists across runs.
  --ro                Mount every workspace read-only (review / audit mode).
  --aws               Opt in to AWS: mount ~/.aws/config + ~/.aws/sso (:ro)
                      and forward AWS_PROFILE / AWS_REGION /
                      AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY /
                      AWS_SESSION_TOKEN when set.
  --gh                Opt in to GitHub via a per-session auth-proxy sidecar:
                      gh/git reach GitHub through a proxy that injects the
                      real token in transit. The agent container never sees
                      it — GH_TOKEN / `gh auth token` return a placeholder.
                      In-container gh login state stays masked while the
                      sidecar is active. Requires a host GitHub token (env
                      or `gh auth token`); silently behaves like today's
                      --gh with no sidecar if none is found. Mutually
                      exclusive with --gh-direct. Env overrides:
                      CLAUDE_DOCKER_PROXY_IMAGE (sidecar image),
                      CLAUDE_DOCKER_GH_POLICY (Caddyfile policy snippet).
  --gh-direct         Legacy GitHub opt-in: forward GH_TOKEN / GITHUB_TOKEN
                      straight into the agent container (no sidecar, no
                      token isolation) and unmask in-container gh login
                      state. For custom-hostname GitHub (Enterprise Server /
                      *.ghe.com) or hosts that can't run the sidecar.
                      Mutually exclusive with --gh.
  --glab              Opt in to GitLab: mount glab-cli config (:ro) and
                      forward GITLAB_TOKEN; unmask in-container glab login.
  --tfe               Opt in to Terraform Cloud (app.terraform.io): mount
                      ~/.terraform.d/credentials.tfrc.json (:ro) when
                      present and forward TF_TOKEN_app_terraform_io;
                      unmask in-container `terraform login` state.
  --registry          Opt in to private package registries: surface host-
                      native uv/npm/pnpm/pip config so in-container installs
                      resolve against a private feed. Mounts ~/.npmrc,
                      ~/.config/uv/uv.toml, and pip.conf (:ro) when present and
                      forwards UV_INDEX_* / npm_config_registry / PIP_* env
                      when set. Runtime only; the image build is unaffected.
                      ~/.netrc is NOT mounted (too broad — see README); npmrc
                      and pip.conf are whole-file mounts, so scope them to the
                      registry. See README "Private package registries".
  --iterm             Wrap claude in tmux -CC (iTerm2 control mode → native
                      panes). Equivalent to CLAUDE_DOCKER_TMUX=cc.
  --tmux              Wrap claude in plain tmux (works in any terminal).
                      Equivalent to CLAUDE_DOCKER_TMUX=1.
  --claude-dir=PATH   Use PATH as the host Claude config dir instead of
                      ~/.claude. Affects agents, commands, skills, CLAUDE.md,
                      and statusline. Env: CLAUDE_DOCKER_CONFIG_DIR.

Separator:
  --                  Ends wrapper-flag parsing. Everything after is passed
                      to `claude`, e.g. `claude-docker ~/repo -- --resume`.

Environment:
  CLAUDE_DOCKER_TMUX       1  → plain tmux wrapper (same as --tmux).
                           cc → tmux -CC iTerm2 control mode (same as
                           --iterm).
  CLAUDE_DOCKER_IMAGE      Override the image tag (default: claude-code:local).
                           Used by child images that extend this one and want to
                           reuse this wrapper.
  CLAUDE_DOCKER_CONFIG_DIR Override the host Claude config dir (same as
                           --claude-dir=PATH).
  CLAUDE_DOCKER_RUNTIME    Container engine to invoke: docker or podman. Unset
                           (default) auto-detects, preferring docker then
                           podman. This is the canonical way to force an engine
                           and works in scripts, CI, and non-interactive shells.
  CLAUDE_DOCKER_PROXY_IMAGE Override the digest-pinned Caddy image used by the
                           --gh auth-proxy sidecar.
  CLAUDE_DOCKER_GH_POLICY  Path to a Caddyfile snippet imported into the --gh
                           sidecar's api.github.com site block, to extend the
                           default request-filtering policy.

Credentials are off by default; combine opt-ins as needed:
  claude-docker --aws --gh ~/repo

Git identity (user.name, user.email) is forwarded automatically from the
host's global git config as GIT_AUTHOR_* / GIT_COMMITTER_* env vars so
in-container `git commit` works without a `-c user.email=...` override.
Not gated: identity is already public on every commit you've ever made.
Signing, credential helpers, and hooks are NOT forwarded.

If <config-dir>/settings.docker.json exists it is copied to settings.json in
the container at startup — writable in-session, re-seeded from the host file
on every run; the regular settings.json is never forwarded automatically.
EOF
}

# Wrapper flags and workspace paths before `--`; verbatim claude flags after.
# See `print_help` above or `claude-docker --help` for the flag list.
WORKSPACES=()
CLAUDE_FLAGS=()
EPHEMERAL=0
RO_WORKSPACES=0
WITH_AWS=0
WITH_GH=0
WITH_GH_DIRECT=0
WITH_GLAB=0
WITH_TFE=0
WITH_REGISTRY=0
CLAUDE_CONFIG_DIR="${CLAUDE_DOCKER_CONFIG_DIR:-$HOME/.claude}"
saw_sep=0
for arg in "$@"; do
  if [ "$arg" = "--" ]; then saw_sep=1; continue; fi
  if [ "$saw_sep" = "1" ]; then
    CLAUDE_FLAGS+=("$arg"); continue
  fi
  case "$arg" in
    -h|--help)      print_help; exit 0 ;;
    --yolo)         CLAUDE_FLAGS+=("--dangerously-skip-permissions") ;;
    --ephemeral)    EPHEMERAL=1 ;;
    --ro)           RO_WORKSPACES=1 ;;
    --aws)          WITH_AWS=1 ;;
    --gh)           WITH_GH=1 ;;
    --gh-direct)    WITH_GH_DIRECT=1 ;;
    --glab)         WITH_GLAB=1 ;;
    --tfe)          WITH_TFE=1 ;;
    --registry)     WITH_REGISTRY=1 ;;
    --iterm)        CLAUDE_DOCKER_TMUX=cc ;;
    --tmux)         CLAUDE_DOCKER_TMUX=1 ;;
    --claude-dir=*) CLAUDE_CONFIG_DIR="${arg#--claude-dir=}" ;;
    -*)             echo "claude-docker: unknown flag '$arg' (use -- to pass flags to claude)" >&2; exit 1 ;;
    *)              WORKSPACES+=("$arg") ;;
  esac
done
[ "${#WORKSPACES[@]}" -eq 0 ] && WORKSPACES=("$PWD")

# --gh (auth-proxy sidecar) and --gh-direct (legacy forwarding) are mutually
# exclusive strategies for the same credential — picking one silently would
# hide the other's risk profile from the user, so reject the combination
# outright (same exit style as the unknown-flag case above).
if [ "$WITH_GH" = "1" ] && [ "$WITH_GH_DIRECT" = "1" ]; then
  echo "claude-docker: --gh and --gh-direct are mutually exclusive — pick the auth-proxy sidecar (--gh) or legacy token forwarding (--gh-direct)" >&2
  exit 1
fi

# Select the container runtime AFTER flag parsing: `-h`/`--help` is handled in
# the loop above and has already exited 0 by now, so this never blocks help on
# an engine-less host; and a real run on such a host fails here — before any
# mktemp/cp staging below. CLAUDE_DOCKER_RUNTIME is the canonical override (works
# in scripts/CI/editors/non-interactive shells); empty means auto-detect.
RUNTIME="${CLAUDE_DOCKER_RUNTIME:-}"
# Allowlist the override — it names the binary invoked as `"$RUNTIME" run` at the
# end of this script, so we must never hand `run …` to an arbitrary on-PATH
# binary. Empty is allowed and means "auto-detect".
case "$RUNTIME" in
  ""|docker|podman) ;;
  *) echo "claude-docker: CLAUDE_DOCKER_RUNTIME must be 'docker' or 'podman', got '$RUNTIME'" >&2; exit 1 ;;
esac
if [ -z "$RUNTIME" ]; then
  if   command -v docker >/dev/null 2>&1; then RUNTIME=docker
  elif command -v podman >/dev/null 2>&1; then RUNTIME=podman
  else echo "claude-docker: no container runtime found — install docker or podman, or set CLAUDE_DOCKER_RUNTIME" >&2; exit 1
  fi
elif ! command -v "$RUNTIME" >/dev/null 2>&1; then
  echo "claude-docker: requested runtime '$RUNTIME' not found on PATH" >&2; exit 1
fi

# Best-effort prune of gh-auth-proxy resources stranded by a prior run.sh that
# died before its EXIT trap could run — the trap installed below (right after
# this session's own stage dir exists) is the primary teardown path; this is
# only insurance. Containers: STOPPED states only (exited/created/dead) — a
# running claude-gh-proxy-* almost certainly belongs to a concurrent live
# session, and `rm -f` would sever its GitHub access mid-flight, so running
# strays (hard-killed run.sh whose sidecar lives on) are deliberately left
# for manual cleanup; the name prefix makes them easy to spot. Networks:
# removal of an in-use network fails and is swallowed, so live sessions are
# safe; an empty network belonging to a session inside its create→sidecar-run
# window can race and lose, which fails that session closed with a clear
# error — rare, safe, retry succeeds. Every failure here is swallowed: a
# stale resource that resists removal must never abort this run.
"$RUNTIME" ps -aq --filter "name=^claude-gh-proxy-" \
    --filter "status=exited" --filter "status=created" --filter "status=dead" \
    2>/dev/null | while IFS= read -r gh_stale_cid; do
  [ -z "$gh_stale_cid" ] && continue
  "$RUNTIME" rm -f "$gh_stale_cid" >/dev/null 2>&1 || true
done || true
"$RUNTIME" network ls -q --filter "name=^claude-gh-" 2>/dev/null | while IFS= read -r gh_stale_nid; do
  [ -z "$gh_stale_nid" ] && continue
  "$RUNTIME" network rm "$gh_stale_nid" >/dev/null 2>&1 || true
done || true

# Git Bash / MSYS / Cygwin on Windows rewrites POSIX-looking argv into Windows
# paths before the native docker.exe/podman.exe sees them, corrupting the
# container-side paths we pass verbatim (/workspaces/<name>, -w, --add-dir,
# /root/..., /run/...) into e.g. "\Program Files\Git\workspaces\...". Disable
# that argv conversion; the host bind-mount *sources* that legitimately need
# Windows form are translated by hostpath() below, since the shell no longer will.
IS_MSYS=0
case "$(uname -s 2>/dev/null)" in
  MINGW*|MSYS*|CYGWIN*) IS_MSYS=1 ;;
esac
if [ "$IS_MSYS" = "1" ]; then
  export MSYS2_ARG_CONV_EXCL='*'   # MSYS2 / newer Git Bash
  export MSYS_NO_PATHCONV=1        # older Git-for-Windows
fi
# Translate a host path to the form the native engine accepts as a bind-mount
# source. Under MSYS, cygpath -m turns /c/Users/foo into C:/Users/foo (drive
# letter + forward slashes, which docker/podman parse correctly). Off-MSYS (or
# if cygpath is somehow absent) it is the identity function, so the Linux/macOS
# argv is byte-for-byte unchanged from the hardcoded-docker behaviour.
hostpath() {
  if [ "$IS_MSYS" = "1" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"
  else
    printf '%s' "$1"
  fi
}

# Emit the gh-auth-proxy sidecar Caddyfile (consumed by the --gh block below)
# to stdout. Deliberately a constant, not a template: every per-run difference
# is resolved by Caddy itself — {$GH_PROXY_UPSTREAM_*} substituted at
# config-load, {env.GH_PROXY_*} (the token) per-request — plus the always-
# present /etc/caddy/policy.caddy import. header_up REPLACES any client-supplied
# Authorization, so the placeholder GH_TOKEN gh/git send is discarded, never
# forwarded; the token reaches Caddy only via {env.*} and never touches disk.
# api.github.com/uploads.github.com take a Bearer token; github.com (git
# smart-HTTP) takes Basic x-access-token:<token> — see design.md. The single
# exception is release-asset HEAD probes on github.com, where the header is
# deleted instead of replaced (see the block itself).
gen_gh_proxy_caddyfile() {
  cat <<'EOF'
{
	admin off
	local_certs
	skip_install_trust
	log {
		output stdout
		format json
	}
}

github.com {
	tls internal
	log {
		output stdout
		format json
	}

	# Release-asset HEAD probes go out anonymous. GitHub routes a HEAD that
	# carries *any* Authorization header to a legacy
	# objects.githubusercontent.com pre-signed URL that then answers 401 to
	# every method, while an anonymous HEAD gets the working
	# release-assets.githubusercontent.com CDN — so uv, which probes with HEAD
	# before GET, cannot install from a release-asset URL (issue #22). The
	# credential buys nothing on this endpoint: github.com's web
	# /releases/download/ path does not accept token auth at all, so a private
	# asset 404s with or without it (the supported route for those is the API
	# asset endpoint, i.e. `gh release download`). Scoped to method+path so
	# every request that works today keeps its credential and its route:
	# authenticated GET is untouched (it already redirects to the working CDN),
	# as are git smart-HTTP, /archive/ and /raw/, none of which change route
	# under auth. -Authorization *deletes* rather than replaces, because the
	# placeholder GH_TOKEN gh/git send would trigger the same legacy routing.
	@gh_release_asset_head {
		method HEAD
		path_regexp ^/[^/]+/[^/]+/releases/download/.+
	}
	handle @gh_release_asset_head {
		reverse_proxy {$GH_PROXY_UPSTREAM_GITHUB} {
			header_up -Authorization
		}
	}

	handle {
		reverse_proxy {$GH_PROXY_UPSTREAM_GITHUB} {
			header_up Authorization "{env.GH_PROXY_BASIC}"
		}
	}
}

api.github.com {
	tls internal
	log {
		output stdout
		format json
	}

	@gh_proxy_repo_delete {
		method DELETE
		path_regexp ^/repos/[^/]+/[^/]+/?$
	}
	respond @gh_proxy_repo_delete "claude-docker gh-proxy policy: repository deletion is blocked by default. Extend policy via CLAUDE_DOCKER_GH_POLICY, or bypass the proxy entirely with --gh-direct." 403
	import /etc/caddy/policy.caddy

	reverse_proxy {$GH_PROXY_UPSTREAM_API} {
		header_up Authorization "{env.GH_PROXY_BEARER}"
	}
}

uploads.github.com {
	tls internal
	log {
		output stdout
		format json
	}
	reverse_proxy {$GH_PROXY_UPSTREAM_UPLOADS} {
		header_up Authorization "{env.GH_PROXY_BEARER}"
	}
}
EOF
}
# Expand a leading ~/ in CLAUDE_CONFIG_DIR — needed when set via env var, where
# the shell does not perform tilde expansion. Pattern is "~/" not "~" so a
# user-tilde form like "~alice/path" is not silently misresolved as "$HOME/alice/path".
# shellcheck disable=SC2088  # literal "~/" is the intended case pattern, not a tilde-expansion target
case "$CLAUDE_CONFIG_DIR" in "~/"*) CLAUDE_CONFIG_DIR="$HOME/${CLAUDE_CONFIG_DIR#\~/}" ;; esac

MOUNT_ARGS=()
ENV_ARGS=(-e TERM)
CONTAINER_PATHS=()

ws_suffix=""
[ "$RO_WORKSPACES" = "1" ] && ws_suffix=":ro"

# Parallel arrays (not associative) so macOS system bash 3.2 works.
# Counter-based iteration avoids ${!arr[@]} which trips set -u on empty arrays.
SEEN_NAMES=()
SEEN_PATHS=()
for ws in "${WORKSPACES[@]}"; do
  abs=$(cd "$ws" && pwd)
  name=$(basename "$abs")
  # Safe: -v/-w/--add-dir all receive the path as a single quoted argv element; only : and empty break docker -v parsing.
  case "$name" in
    "")  echo "claude-docker: workspace basename is empty; cannot mount at /workspaces/" >&2; exit 1 ;;
    *:*) echo "claude-docker: workspace basename '$name' cannot contain ':' (breaks docker -v parsing)" >&2; exit 1 ;;
  esac
  n=${#SEEN_NAMES[@]}
  i=0
  while [ "$i" -lt "$n" ]; do
    if [ "${SEEN_NAMES[$i]}" = "$name" ]; then
      echo "claude-docker: workspace basename collision — '$abs' and '${SEEN_PATHS[$i]}' both map to /workspaces/$name" >&2
      exit 1
    fi
    i=$((i + 1))
  done
  SEEN_NAMES+=("$name")
  SEEN_PATHS+=("$abs")
  MOUNT_ARGS+=("-v" "$(hostpath "$abs"):/workspaces/$name$ws_suffix")
  CONTAINER_PATHS+=("/workspaces/$name")
done
CWD="${CONTAINER_PATHS[0]}"

# File-based host creds. gh uses macOS Keychain → log in inside the container once; persists via claude-code-root.
# glab on macOS lives under ~/Library/Application Support/glab-cli (not XDG); fall back to ~/.config/glab-cli on Linux.
if [ "$WITH_GLAB" = "1" ]; then
  glab_src=""
  if [ -d "$HOME/Library/Application Support/glab-cli" ]; then
    glab_src="$HOME/Library/Application Support/glab-cli"
  elif [ -d "$HOME/.config/glab-cli" ]; then
    glab_src="$HOME/.config/glab-cli"
  fi
  [ -n "$glab_src" ] && MOUNT_ARGS+=("-v" "$(hostpath "$glab_src"):/root/.config/glab-cli:ro")
fi

# Scoped AWS mount: only non-secret config + short-lived SSO bearer cache.
# Excludes ~/.aws/credentials (long-lived access keys) and ~/.aws/cli/cache
# (cached assume-role STS). Env-var flow (AWS_ACCESS_KEY_ID/...) still forwards
# below for users who flatten creds with `aws configure export-credentials`.
if [ "$WITH_AWS" = "1" ]; then
  [ -f "$HOME/.aws/config" ] && MOUNT_ARGS+=("-v" "$(hostpath "$HOME/.aws/config"):/root/.aws/config:ro")
  [ -d "$HOME/.aws/sso" ]    && MOUNT_ARGS+=("-v" "$(hostpath "$HOME/.aws/sso"):/root/.aws/sso:ro")
fi

# Terraform Cloud credentials file written by `terraform login`. Standard
# location on every platform is ~/.terraform.d/credentials.tfrc.json. Only
# app.terraform.io is in scope here; the file format supports other hosts
# but mounting them is intentional and out of scope for --tfe.
if [ "$WITH_TFE" = "1" ]; then
  [ -f "$HOME/.terraform.d/credentials.tfrc.json" ] \
    && MOUNT_ARGS+=("-v" "$(hostpath "$HOME/.terraform.d/credentials.tfrc.json"):/root/.terraform.d/credentials.tfrc.json:ro")
fi

# Private package registries: surface the host's native uv/npm/pnpm/pip registry
# config read-only so in-container installs resolve against a private feed
# (CodeArtifact / Artifactory / Nexus / …). Each mount is a silent no-op when the
# host file is absent. The pip user config dir is platform-specific (macOS keeps
# it under Application Support, Linux under XDG ~/.config); both map to the
# container's Linux path /root/.config/pip/pip.conf. Read-only, like every other
# cred mount. NOTE: ~/.netrc is deliberately NOT mounted — it is a machine-keyed
# store that routinely holds credentials for hosts unrelated to the registry, so
# forwarding the whole file into a full-egress container is too broad. Use
# registry auth that lives in npmrc/pip.conf, the URL, or UV_INDEX_*_PASSWORD.
if [ "$WITH_REGISTRY" = "1" ]; then
  # npm/pnpm read ~/.npmrc by default, but honour a relocated userconfig
  # (npm_config_userconfig / NPM_CONFIG_USERCONFIG) so a host that moved its
  # npmrc doesn't silently fall through to the public registry. Whatever the
  # host source, mount it at the container's default /root/.npmrc — and we do
  # NOT forward npm_config_userconfig, so the in-container npm keeps that path.
  npmrc_src="${npm_config_userconfig:-${NPM_CONFIG_USERCONFIG:-$HOME/.npmrc}}"
  [ -f "$npmrc_src" ]               && MOUNT_ARGS+=("-v" "$(hostpath "$npmrc_src"):/root/.npmrc:ro")
  [ -f "$HOME/.config/uv/uv.toml" ] && MOUNT_ARGS+=("-v" "$(hostpath "$HOME/.config/uv/uv.toml"):/root/.config/uv/uv.toml:ro")
  pip_conf=""
  if [ -f "$HOME/Library/Application Support/pip/pip.conf" ]; then
    pip_conf="$HOME/Library/Application Support/pip/pip.conf"
  elif [ -f "$HOME/.config/pip/pip.conf" ]; then
    pip_conf="$HOME/.config/pip/pip.conf"
  fi
  [ -n "$pip_conf" ] && MOUNT_ARGS+=("-v" "$(hostpath "$pip_conf"):/root/.config/pip/pip.conf:ro")
fi

ENV_VARS=()
# GH_TOKEN/GITHUB_TOKEN are forwarded verbatim only under --gh-direct: under
# --gh the token instead goes to the auth-proxy sidecar (see below), never
# into the agent container.
[ "$WITH_GH_DIRECT" = "1" ] && ENV_VARS+=(GH_TOKEN GITHUB_TOKEN)
[ "$WITH_GLAB" = "1" ] && ENV_VARS+=(GITLAB_TOKEN)
[ "$WITH_AWS" = "1" ]  && ENV_VARS+=(AWS_PROFILE AWS_REGION AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN)
[ "$WITH_TFE" = "1" ]  && ENV_VARS+=(TF_TOKEN_app_terraform_io)
# --registry: forward the native registry-config env vars uv/npm/pnpm/pip read.
# Static, fixed-name vars here; uv's dynamic per-index credential vars (whose
# names embed a user-chosen index name) are handled by the scan below.
# UV_NETRC is intentionally omitted: it points uv at a netrc file we no longer
# mount, so forwarding it would dangle at a host path absent in the container.
[ "$WITH_REGISTRY" = "1" ] && ENV_VARS+=(npm_config_registry NPM_CONFIG_REGISTRY NODE_AUTH_TOKEN NPM_TOKEN UV_INDEX_URL UV_DEFAULT_INDEX UV_EXTRA_INDEX_URL UV_INDEX UV_KEYRING_PROVIDER PIP_INDEX_URL PIP_EXTRA_INDEX_URL PIP_TRUSTED_HOST PIPENV_PYPI_MIRROR)
# Guarded: bash 3.2 under `set -u` errors on empty-array expansion.
if [ "${#ENV_VARS[@]}" -gt 0 ]; then
  for v in "${ENV_VARS[@]}"; do
    [ -n "${!v:-}" ] && ENV_ARGS+=("-e" "$v")
  done
fi
# uv's per-index credentials are UV_INDEX_<NAME>_USERNAME / _PASSWORD, where
# <NAME> is a user-chosen index name — a fixed list can't enumerate them. Scan
# the exported host vars and forward matches, scoped STRICTLY to those two
# suffixes: a blanket UV_* would drag in path-valued vars like UV_CACHE_DIR that
# point at host paths absent in the container. Safe under set -u (read assigns).
if [ "$WITH_REGISTRY" = "1" ]; then
  while IFS= read -r _name; do
    case "$_name" in
      UV_INDEX_*_USERNAME|UV_INDEX_*_PASSWORD)
        [ -n "${!_name:-}" ] && ENV_ARGS+=("-e" "$_name") ;;
    esac
  done < <(compgen -e)
fi
# GitHub token discovery — shared, unchanged, by --gh and --gh-direct: host
# env (GH_TOKEN/GITHUB_TOKEN) wins; else fall back to the gh CLI's active
# token so users authenticated via `gh auth login` don't have to export
# anything manually; else silent skip (gh absent or not logged in). What
# differs is disposition: --gh-direct forwards the result into the agent
# container (below, mirroring the legacy --gh behavior this preserves);
# --gh instead hands it only to the auth-proxy sidecar, further down.
GH_DISCOVERED_TOKEN=""
if { [ "$WITH_GH" = "1" ] || [ "$WITH_GH_DIRECT" = "1" ]; } \
   && [ -z "${GH_TOKEN:-}" ] && [ -z "${GITHUB_TOKEN:-}" ] \
   && command -v gh >/dev/null 2>&1; then
  GH_DISCOVERED_TOKEN=$(gh auth token 2>/dev/null) || true
fi
if [ "$WITH_GH_DIRECT" = "1" ] && [ -n "$GH_DISCOVERED_TOKEN" ]; then
  GH_TOKEN="$GH_DISCOVERED_TOKEN"
  export GH_TOKEN
  ENV_ARGS+=("-e" "GH_TOKEN")
fi
# Token handed to the --gh auth-proxy sidecar setup below, mirroring the
# discovery precedence above (host env wins over the gh-CLI fallback). Empty
# when --gh wasn't passed or no token was found either way.
GH_HOST_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-$GH_DISCOVERED_TOKEN}}"

# Forward host git identity so in-container `git commit` works without a
# per-invocation `-c user.email=...` dance. Non-opt-in: user.name/user.email
# are already on every public commit the user has ever made, so there is no
# credential to gate. GIT_AUTHOR_* / GIT_COMMITTER_* take precedence over
# config and are sufficient for commits; we deliberately skip signing and
# other host-specific settings (credential helpers, hooks) that wouldn't
# work in the container anyway.
if command -v git >/dev/null 2>&1; then
  if git_name=$(git config --global --get user.name 2>/dev/null) && [ -n "$git_name" ]; then
    ENV_ARGS+=("-e" "GIT_AUTHOR_NAME=$git_name" "-e" "GIT_COMMITTER_NAME=$git_name")
  fi
  if git_email=$(git config --global --get user.email 2>/dev/null) && [ -n "$git_email" ]; then
    ENV_ARGS+=("-e" "GIT_AUTHOR_EMAIL=$git_email" "-e" "GIT_COMMITTER_EMAIL=$git_email")
  fi
fi

# Surface active opt-ins in-container via CLAUDE_DOCKER_FLAGS so the statusline
# wrapper (below) can tag the session with what was actually granted. Order
# mirrors the README table so the tag reads predictably.
# --yolo is omitted intentionally: Claude Code already shows the permission
# mode in its UI, so duplicating it here would just be noise.
DOCKER_FLAGS=()
[ "$WITH_GH" = "1" ]       && DOCKER_FLAGS+=("gh")
[ "$WITH_GH_DIRECT" = "1" ] && DOCKER_FLAGS+=("gh-direct")
[ "$WITH_AWS" = "1" ]      && DOCKER_FLAGS+=("aws")
[ "$WITH_GLAB" = "1" ]     && DOCKER_FLAGS+=("glab")
[ "$WITH_TFE" = "1" ]      && DOCKER_FLAGS+=("tfe")
[ "$WITH_REGISTRY" = "1" ] && DOCKER_FLAGS+=("registry")
[ "$EPHEMERAL" = "1" ]     && DOCKER_FLAGS+=("ephemeral")
[ "$RO_WORKSPACES" = "1" ] && DOCKER_FLAGS+=("ro")
if [ "${#DOCKER_FLAGS[@]}" -gt 0 ]; then
  old_ifs=$IFS; IFS=','; DOCKER_FLAGS_CSV="${DOCKER_FLAGS[*]}"; IFS=$old_ifs
  ENV_ARGS+=("-e" "CLAUDE_DOCKER_FLAGS=$DOCKER_FLAGS_CSV")
fi

# Host Claude config parity: mount host config items read-only into the container.
# Directories: resolve the top-level symlink so Docker gets a real path under
# /Users (which is the only host path Colima shares into its VM by default;
# Docker Desktop also shares it). The statusline wrapper is generated content
# so it still needs a real stage dir — stage that under $HOME for the same
# reason: /tmp and $TMPDIR are NOT shared by Colima's default mount config,
# so any bind-mount from those paths silently yields an empty mountpoint in
# the container. $TMPDIR on macOS is /var/folders/... (not shared by either
# runtime); /tmp is shared by Docker Desktop only.
stage_root="$HOME/.cache/claude-docker"
mkdir -p "$stage_root"
stage=$(mktemp -d "$stage_root/host.XXXXXX")

# GitHub auth-proxy sidecar session identity, derived from the stage-dir
# suffix so it's already unique (mktemp did the work) with no extra
# bookkeeping. Named here — immediately after the stage dir exists but
# before ANY docker resource is created — purely so the EXIT trap below can
# be extended before there is anything for it to clean up. Actual sidecar
# creation (gated on --gh finding a host token) happens further down.
gh_sid="${stage##*.}"
GH_PROXY_NETWORK="claude-gh-$gh_sid"
GH_PROXY_SIDECAR="claude-gh-proxy-$gh_sid"

# `case` instead of `[[ ]]` for bash 3.2 friendliness inside the trap string.
# $HOME/$RUNTIME/$GH_PROXY_* are expanded at trap execution time, * is a glob
# wildcard. The sidecar/network removals are unconditional and tolerate
# not-yet-existing resources (`|| true`): trap-before-create closes the
# window where a failure between creating a resource and re-trapping would
# leak it, so this must be in place before the network/sidecar are created.
trap '
case "$stage" in "$HOME/.cache/claude-docker/host."*) rm -rf "$stage" ;; esac
"$RUNTIME" rm -f "$GH_PROXY_SIDECAR" >/dev/null 2>&1 || true
"$RUNTIME" network rm "$GH_PROXY_NETWORK" >/dev/null 2>&1 || true
' EXIT

# GitHub auth-proxy sidecar: active only when --gh found a host token
# (GH_HOST_TOKEN, computed above during token discovery). --gh-direct and
# the no-token fallback never reach this block — see gh-auth-proxy-sidecar.
GH_SIDECAR_ACTIVE=0
if [ "$WITH_GH" = "1" ] && [ -n "$GH_HOST_TOKEN" ]; then
  mkdir -p "$stage/gh-proxy"

  # Everything that varies between runs is injected into the sidecar's
  # environment, not the config text: the upstreams here and the token
  # further down. Real GitHub by default; the test-only
  # CLAUDE_DOCKER_GH_UPSTREAM hook repoints all three at a single mock
  # upstream (undocumented — for the tests/ integration harness only). Caddy
  # substitutes these {$VAR} references at config-load time.
  GH_PROXY_UPSTREAM_GITHUB="https://github.com"
  GH_PROXY_UPSTREAM_API="https://api.github.com"
  GH_PROXY_UPSTREAM_UPLOADS="https://uploads.github.com"
  if [ -n "${CLAUDE_DOCKER_GH_UPSTREAM:-}" ]; then
    GH_PROXY_UPSTREAM_GITHUB="$CLAUDE_DOCKER_GH_UPSTREAM"
    GH_PROXY_UPSTREAM_API="$CLAUDE_DOCKER_GH_UPSTREAM"
    GH_PROXY_UPSTREAM_UPLOADS="$CLAUDE_DOCKER_GH_UPSTREAM"
  fi
  export GH_PROXY_UPSTREAM_GITHUB GH_PROXY_UPSTREAM_API GH_PROXY_UPSTREAM_UPLOADS

  # The policy file is ALWAYS staged and mounted — the user's snippet when
  # CLAUDE_DOCKER_GH_POLICY is set, an empty file otherwise — so the Caddyfile
  # can `import` it unconditionally (importing an empty file is a no-op). That
  # keeps the config free of a conditional import line, i.e. fully static.
  if [ -n "${CLAUDE_DOCKER_GH_POLICY:-}" ] && [ -f "$CLAUDE_DOCKER_GH_POLICY" ]; then
    cp "$CLAUDE_DOCKER_GH_POLICY" "$stage/gh-proxy/policy.caddy"
  else
    : > "$stage/gh-proxy/policy.caddy"
  fi

  # Static config emitted by gen_gh_proxy_caddyfile() (near hostpath above);
  # everything variable is resolved by Caddy from the sidecar env and the
  # policy import, not by the shell.
  gen_gh_proxy_caddyfile >"$stage/gh-proxy/Caddyfile"

  if ! "$RUNTIME" network create "$GH_PROXY_NETWORK" >/dev/null; then
    echo "claude-docker: failed to create network '$GH_PROXY_NETWORK' for the gh-auth-proxy sidecar — aborting (the real GitHub token was never forwarded)" >&2
    exit 1
  fi

  # Complete header values, scheme prefix included, computed host-side and
  # passed to the sidecar's environment only — never written to the staged
  # Caddyfile and never forwarded into the agent container. Exported here and
  # forwarded by bare name (-e NAME, no value) so the token never appears in
  # the docker CLI's argv: /proc/<pid>/cmdline is world-readable on Linux,
  # while environ is owner-only. tr -d '\n' is required: GNU base64 wraps at
  # 76 columns (the encoded credential exceeds that), BSD base64 does not —
  # stripping newlines unconditionally is correct either way.
  GH_PROXY_BASIC="Basic $(printf '%s' "x-access-token:$GH_HOST_TOKEN" | base64 | tr -d '\n')"
  GH_PROXY_BEARER="Bearer $GH_HOST_TOKEN"
  export GH_PROXY_BASIC GH_PROXY_BEARER

  # Both mounts are unconditional: policy.caddy is always staged (empty when
  # the user set no policy) so the Caddyfile's unconditional import resolves.
  GH_SIDECAR_MOUNTS=(
    -v "$(hostpath "$stage/gh-proxy/Caddyfile"):/etc/caddy/Caddyfile:ro"
    -v "$(hostpath "$stage/gh-proxy/policy.caddy"):/etc/caddy/policy.caddy:ro"
  )

  # No published ports: the sidecar is reachable only from the agent
  # container, over the session-private network created above. Capabilities
  # dropped to the one Caddy needs (binding <1024 as non-root).
  # Deliberately NOT --rm: `run -d` reports success as soon as the container
  # *starts*, so a Caddy that exits immediately (most often an invalid
  # CLAUDE_DOCKER_GH_POLICY snippet) needs its logs to diagnose — with --rm the
  # container, and its logs, would already be gone by the time we notice. The
  # EXIT trap removes it on session end; a stopped stray from a hard-killed
  # run.sh is swept by the stopped-only prune at the next start.
  if ! "$RUNTIME" run -d \
      --name "$GH_PROXY_SIDECAR" \
      --network "$GH_PROXY_NETWORK" \
      --cap-drop ALL --cap-add NET_BIND_SERVICE \
      --security-opt no-new-privileges \
      -e GH_PROXY_BEARER \
      -e GH_PROXY_BASIC \
      -e GH_PROXY_UPSTREAM_GITHUB \
      -e GH_PROXY_UPSTREAM_API \
      -e GH_PROXY_UPSTREAM_UPLOADS \
      "${GH_SIDECAR_MOUNTS[@]}" \
      "$PROXY_IMAGE" >/dev/null; then
    echo "claude-docker: failed to start the gh-auth-proxy sidecar ($PROXY_IMAGE) — aborting; the real GitHub token was never forwarded into any container. Try '$RUNTIME pull $PROXY_IMAGE', or use --gh-direct to bypass the proxy." >&2
    exit 1
  fi

  # Caddy materializes its local CA root at config load, not lazily on first
  # TLS handshake (verified against the pinned image per design.md) — this
  # loop is a startup-race guard, not a wait for lazy generation. ~15s total
  # budget, short retries.
  gh_ca_ready=0
  gh_proxy_exited=0
  i=0
  while [ "$i" -lt 15 ]; do
    if "$RUNTIME" cp "$GH_PROXY_SIDECAR:/data/caddy/pki/authorities/local/root.crt" "$stage/gh-proxy/root.crt" >/dev/null 2>&1; then
      gh_ca_ready=1
      break
    fi
    # Distinguish "still starting" from "already dead" so a config error is
    # reported as itself instead of waiting out the budget and blaming the CA.
    if [ -z "$("$RUNTIME" ps -q --filter "name=^$GH_PROXY_SIDECAR$" 2>/dev/null)" ]; then
      gh_proxy_exited=1
      break
    fi
    sleep 1
    i=$((i + 1))
  done
  if [ "$gh_proxy_exited" = "1" ]; then
    echo "claude-docker: the gh-auth-proxy sidecar exited during startup — aborting; the real GitHub token was never forwarded into any container. Caddy's own error follows (an invalid CLAUDE_DOCKER_GH_POLICY snippet is the usual cause):" >&2
    "$RUNTIME" logs "$GH_PROXY_SIDECAR" 2>&1 | tail -15 | sed 's/^/  | /' >&2
    exit 1
  fi
  if [ "$gh_ca_ready" != "1" ]; then
    echo "claude-docker: gh-auth-proxy sidecar did not produce a CA certificate within 15s — aborting; the real GitHub token was never forwarded into any container. The sidecar is still running; inspect it with '$RUNTIME logs $GH_PROXY_SIDECAR' (it is removed when this command exits)." >&2
    exit 1
  fi

  gh_proxy_ip=$("$RUNTIME" inspect --format "{{(index .NetworkSettings.Networks \"$GH_PROXY_NETWORK\").IPAddress}}" "$GH_PROXY_SIDECAR" 2>/dev/null)
  if [ -z "$gh_proxy_ip" ]; then
    echo "claude-docker: could not determine the gh-auth-proxy sidecar's network address — aborting; the real GitHub token was never forwarded into any container." >&2
    exit 1
  fi

  # Wire the agent container: redirect only the three GitHub hostnames that
  # need the Authorization header to the sidecar (--add-host rewrites
  # resolution inside the agent container only — see design.md on why this
  # beats a network alias), trust the sidecar's CA, and hand `gh` a
  # placeholder that satisfies its "am I authenticated" check without being
  # a usable credential.
  MOUNT_ARGS+=(
    "--network" "$GH_PROXY_NETWORK"
    "--add-host" "github.com:$gh_proxy_ip"
    "--add-host" "api.github.com:$gh_proxy_ip"
    "--add-host" "uploads.github.com:$gh_proxy_ip"
    "-v" "$(hostpath "$stage/gh-proxy/root.crt"):/usr/local/share/ca-certificates/claude-docker-gh-proxy.crt:ro"
  )
  # UV_SYSTEM_CERTS makes uv read the OS trust store instead of the webpki roots
  # bundled into its rustls client — without it uv is the one shipped tool that
  # trusts neither the system bundle nor NODE_EXTRA_CA_CERTS, so every
  # github.com fetch fails "invalid peer certificate: UnknownIssuer" while git,
  # gh and curl work (issue #22). Full verification is preserved: uv verifies
  # against the same entrypoint-installed session root. Set only alongside the
  # sidecar, mirroring NODE_EXTRA_CA_CERTS — with no interception there is
  # nothing extra to trust. (Env name over the deprecated UV_NATIVE_TLS; both
  # are honoured by the pinned uv, only the new one is warning-free.)
  ENV_ARGS+=(
    "-e" "GH_TOKEN=claude-docker-proxy"
    "-e" "NODE_EXTRA_CA_CERTS=/usr/local/share/ca-certificates/claude-docker-gh-proxy.crt"
    "-e" "UV_SYSTEM_CERTS=1"
  )
  GH_SIDECAR_ACTIVE=1
  echo "claude-docker: gh-auth-proxy sidecar '$GH_PROXY_SIDECAR' is active — view the audit log with: $RUNTIME logs $GH_PROXY_SIDECAR" >&2
fi

for item in agents commands skills; do
  src="$CLAUDE_CONFIG_DIR/$item"
  # Resolve top-level symlink so cp -RL gets a real directory path, not a link.
  # Hop counter guards against pathological symlink cycles (a -> b -> a).
  hops=0
  while [ -L "$src" ] && [ "$hops" -lt 10 ]; do
    link=$(readlink "$src")
    case "$link" in /*) src="$link" ;; *) src="$(dirname "$src")/$link" ;; esac
    hops=$((hops + 1))
  done
  if [ -d "$src" ]; then
    # cp -RL dereferences all symlinks within the tree so internal symlinks
    # (e.g. skills/foo -> ~/git/repo/skills/foo) resolve inside the container.
    cp -RL "$src" "$stage/$item"
    MOUNT_ARGS+=("-v" "$(hostpath "$stage/$item"):/root/.claude/$item:ro")
  fi
done
if [ -f "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]; then
  MOUNT_ARGS+=("-v" "$(hostpath "$CLAUDE_CONFIG_DIR/CLAUDE.md"):/root/.claude/CLAUDE.md:ro")
fi

# Statusline: mount the host script as-is, plus a thin wrapper at the canonical
# path that prefixes a `docker:<flags>` tag when CLAUDE_DOCKER_FLAGS is set.
# The wrapper is a no-op passthrough when unset so non-claude-docker runs of
# the same file would behave identically.
if [ -f "$CLAUDE_CONFIG_DIR/statusline-command.sh" ]; then
  cat >"$stage/statusline-command.sh" <<'WRAP'
#!/bin/sh
# claude-docker wrapper — prepends active opt-in flag tag to host statusline.
input=$(cat)
body=$(printf '%s' "$input" | sh /root/.claude/statusline-command.original.sh)
if [ -n "${CLAUDE_DOCKER_FLAGS:-}" ]; then
  printf '\033[33mdocker:%s\033[0m %s' "$CLAUDE_DOCKER_FLAGS" "$body"
else
  printf '%s' "$body"
fi
WRAP
  chmod +x "$stage/statusline-command.sh"
  MOUNT_ARGS+=(
    "-v" "$(hostpath "$CLAUDE_CONFIG_DIR/statusline-command.sh"):/root/.claude/statusline-command.original.sh:ro"
    "-v" "$(hostpath "$stage/statusline-command.sh"):/root/.claude/statusline-command.sh:ro"
  )
fi
# Settings are forwarded via a seed path + entrypoint copy, NOT bind-mounted
# at /root/.claude/settings.json directly: Claude Code persists settings by
# renaming a tmp file over settings.json, and rename() over a mountpoint fails
# with EBUSY (regardless of :ro), so a direct mount breaks every in-session
# settings change (effort, model, theme). The entrypoint copies the seed onto
# the container filesystem so those writes work; changes last for the run and
# are overwritten from the host file on the next start — never written back.
[ -f "$CLAUDE_CONFIG_DIR/settings.docker.json" ] \
  && MOUNT_ARGS+=("-v" "$(hostpath "$CLAUDE_CONFIG_DIR/settings.docker.json"):/run/claude-docker/settings.json:ro")

# Container-only .git/config overlay: enable relative-path worktrees inside the
# container without touching the host's on-disk repo config. The host file
# stays unmodified, so host tools that bundle an old libgit2 (notably
# gitstatusd → Powerlevel10k) keep opening the repo fine; only the container's
# view of .git/config declares extensions.relativeWorktrees, so git inside the
# container writes relative paths into worktree link files. Those link files
# live in the shared on-disk tree and are readable by both ends.
# Bumping core.repositoryformatversion to 1 in the overlay is required — git
# refuses an extensions entry on a v0 repo ("v1-only extension found").
# Overlay is NOT mounted :ro: container-side `git config` / `git remote add`
# need to succeed; those writes land in the ephemeral overlay and are dropped
# at exit, which matches the trade-off documented in the README.
# Counter loop for bash 3.2 (no "${!arr[@]}" on indexed arrays).
n=${#SEEN_NAMES[@]}
i=0
while [ "$i" -lt "$n" ]; do
  ws_abs="${SEEN_PATHS[$i]}"
  ws_name="${SEEN_NAMES[$i]}"
  # Skip workspaces where .git is a worktree/submodule pointer file rather
  # than a directory — only the main repo's .git/config needs the overlay,
  # and the worktree resolves through the main repo's mount anyway.
  if [ -f "$ws_abs/.git/config" ]; then
    cp "$ws_abs/.git/config" "$stage/git-config-$ws_name"
    cat >>"$stage/git-config-$ws_name" <<'EOF'

[core]
	repositoryformatversion = 1
[extensions]
	relativeWorktrees = true
[worktree]
	useRelativePaths = true
EOF
    MOUNT_ARGS+=("-v" "$(hostpath "$stage/git-config-$ws_name"):/workspaces/$ws_name/.git/config")
  fi
  i=$((i + 1))
done

CMD=(claude)
# Grant claude read/write access to every mounted workspace, not just cwd.
# Index 0 is already cwd, so skip it. Repeat --add-dir is allowed; we don't
# dedupe against any user-supplied --add-dir after `--`.
n=${#CONTAINER_PATHS[@]}
i=1
while [ "$i" -lt "$n" ]; do
  CMD+=("--add-dir" "${CONTAINER_PATHS[$i]}")
  i=$((i + 1))
done
[ "${#CLAUDE_FLAGS[@]}" -gt 0 ] && CMD+=("${CLAUDE_FLAGS[@]}")
# Test-only hook for the run.sh-driven integration harness (tests/): replace
# the agent container's command entirely so the harness can run assertions
# in-container instead of claude. Undocumented — not a supported user-facing
# override.
if [ -n "${CLAUDE_DOCKER_TEST_ENTRY:-}" ]; then
  CMD=(sh -c "$CLAUDE_DOCKER_TEST_ENTRY")
fi
# CLAUDE_DOCKER_TMUX=1   → plain tmux (works in any terminal)
# CLAUDE_DOCKER_TMUX=cc  → tmux -CC, iTerm2 control mode (native panes on macOS).
#                          Host must NOT already be inside tmux -CC — nesting
#                          collapses the inner server to plain splits.
# Wrap claude so a fast non-zero exit (e.g. `claude -w` from a non-git dir)
# stays readable: tmux tears the pane down the moment its command exits AND
# always returns 0 itself, so without this hold the user sees neither the
# error message nor a non-zero status — the wrapper just appears to no-op.
HOLD_ON_ERR='"$@"; rc=$?; if [ $rc -ne 0 ]; then printf "\n[%s exited %d — press Enter to close] " "$1" "$rc" >&2; read -r _; fi; exit $rc'
case "${CLAUDE_DOCKER_TMUX:-0}" in
  cc|CC) CMD=(tmux -u -CC new-session -A -s claude sh -c "$HOLD_ON_ERR" _ "${CMD[@]}") ;;
  1)     CMD=(tmux -u     new-session -A -s claude sh -c "$HOLD_ON_ERR" _ "${CMD[@]}") ;;
esac

# Persistent named volumes carry OAuth tokens, gh login, conversation history.
# --ephemeral skips them for one-shot untrusted sessions. Prepend to MOUNT_ARGS
# so the docker run line has no conditionally-empty array (bash 3.2 set -u).
if [ "$EPHEMERAL" = "0" ]; then
  # Mask persisted in-container auth state when the opt-in flag is off, so a
  # prior `gh`/`glab`/`terraform` auth login stored under claude-code-root
  # doesn't leak into a session the user didn't ask to grant those creds to.
  # gh is the exception with three states, not two: masked whenever --gh is
  # absent OR the sidecar is active (the placeholder env token makes
  # persisted login state unnecessary, and leaving it accessible would
  # reintroduce a persisted in-container secret) — unmasked only for --gh
  # with no host token found (in-container login is the remaining auth
  # path, unchanged from before this sidecar existed) and for --gh-direct.
  gh_config_unmask=0
  [ "$WITH_GH_DIRECT" = "1" ] && gh_config_unmask=1
  [ "$WITH_GH" = "1" ] && [ "$GH_SIDECAR_ACTIVE" = "0" ] && gh_config_unmask=1
  [ "$gh_config_unmask" = "0" ] && MOUNT_ARGS+=("--tmpfs" "/root/.config/gh")
  [ "$WITH_GLAB" = "0" ] && MOUNT_ARGS+=("--tmpfs" "/root/.config/glab-cli")
  [ "$WITH_TFE" = "0" ]  && MOUNT_ARGS+=("--tmpfs" "/root/.terraform.d")
  MOUNT_ARGS=(-v claude-code-root:/root -v claude-code-home:/root/.claude "${MOUNT_ARGS[@]}")
fi

# CHOWN/SETUID/SETGID are needed by entrypoint.sh to chown /root and then
# exec runuser. DAC_READ_SEARCH lets the chown step traverse HOST_UID-owned,
# mode-0700 directories under /root — narrower than DAC_OVERRIDE since we
# only need search/read, not write override. All four caps are
# cleared from the effective/permitted/ambient sets when runuser
# transitions UID 0 → host UID; the bounding set keeps them but is inert
# under no-new-privileges, so claude itself runs with no usable caps.
# --init wraps the process tree under tini so claude's bash/MCP children
# get reaped — runuser would otherwise be PID 1 and wouldn't reap zombies.
"$RUNTIME" run --rm -it --init \
  --security-opt no-new-privileges \
  --cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_READ_SEARCH \
  -e "HOST_UID=$(id -u)" -e "HOST_GID=$(id -g)" \
  "${MOUNT_ARGS[@]}" \
  "${ENV_ARGS[@]}" \
  -w "$CWD" \
  "$IMAGE" \
  "${CMD[@]}"
