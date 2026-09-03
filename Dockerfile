# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# Pinned base image (digest pins all arches via the multi-arch index).
# Bump with: docker buildx imagetools inspect ubuntu:26.04 --format '{{.Manifest.Digest}}'
# Ubuntu (not Debian): only ubuntu:26.04 ships git ≥ 2.48 in its main archive,
# needed for the `extensions.relativeWorktrees` repo extension. Rationale and
# alternatives in openspec/changes/worktree-relative-paths/design.md.
FROM ubuntu:resolute-20260811.1@sha256:2260313b31c8c011cd2eebe728008efac1b3982be73eb71348ea2648d2c0e09b

# pipefail propagates failures in RUN ... | ... — without this, a failed curl
# into tee/sha256sum silently succeeds and the build continues with bad data.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# nodejs stays a MANUAL pin: NodeSource's apt repo is signed, and its publish
# dates aren't cleanly machine-readable for the soak, so update_pins.py leaves
# it alone and only reminds the operator to check it.
# NODE_VERSION format is NodeSource's: <upstream>-1nodesource1.
# Bump with: curl -fsSL https://deb.nodesource.com/node_24.x/dists/nodistro/main/binary-amd64/Packages.gz | gunzip | grep -E '^(Package|Version):' | head -4
ARG NODE_VERSION=24.20.0-1nodesource1

# task (go-task) is the same class of MANUAL pin as nodejs above: it installs from
# a signed apt repo (Cloudsmith), and update_pins.py only knows how to pin direct
# downloads by URL + sha256, so it never rewrites this ARG. It does REPORT on it:
# each run reads the same Packages index as the command below (for the suite the
# FROM tag names) and flags the pin when a newer version has been published. That
# report is the only thing watching this pin — Cloudsmith retains every published
# version, so a stale pin keeps building successfully and forever.
# Bump with (stanza-scoped and sorted, so it agrees with update_pins.py rather
# than trusting the index's happens-to-be-newest-first order):
# Bump with: curl -fsSL https://dl.cloudsmith.io/public/task/task/deb/ubuntu/dists/resolute/main/binary-amd64/Packages.gz | gunzip | awk '/^Package: task$/{t=1} /^Version:/{if(t){print $2; t=0}} /^$/{t=0}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1
ARG TASK_VERSION=3.53.1

# Go is the other MANUAL pin (ARG GO_VERSION + per-arch sha256, see its block
# below): go.dev's release feed has no publish dates, so update_pins.py can't
# soak-gate it and only reports how the pin compares to the latest stable.
#
# Every other tool's version (and per-arch sha256) is a GENERATED pin under
# pins/<tool>.env — NOT an ARG. Each install RUN below COPYs and sources its
# fragment, so `docker build .` is reproducible from the committed lockfile with
# no --build-arg. Refresh them with uv run update_pins.py (see README): it selects
# the newest stable version already past a 7-day soak window and recomputes the
# hashes. The soak policy that used to be hand-applied here now lives in that
# script. To override a single tool: uv run update_pins.py --pin <tool>=<version>.

# Make apt runnable under --cap-drop ALL at runtime. Two pieces:
#  1. APT::Sandbox::User "root" stops the http method from setgroups()→_apt
#     (needs CAP_SETGID, dropped at runtime).
#  2. chown archives/partial to root so apt can write it without
#     CAP_DAC_OVERRIDE/CAP_FOWNER — Ubuntu ships it as _apt:root 0700.
#     lists/partial doesn't need chowning: apt re-creates it as root at
#     runtime now that sandbox user is root.
# Safe here: the container itself is the security boundary, not apt's
# internal user split.
RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/10no-sandbox \
 && chown root:root /var/cache/apt/archives/partial

# Free UID/GID 1000. Ubuntu's base image ships a default `ubuntu` user at
# 1000:1000 — i.e. exactly the typical host UID. The entrypoint creates a
# fresh `claude` user mapped to HOST_UID; without this step its `useradd`
# is skipped on collision and `runuser -u claude` then fails. Reusing the
# baked-in `ubuntu` account would also silently inherit its supplementary
# groups (sudo, adm, plugdev, …). Guarded so a future base image without
# the default user doesn't break the build.
RUN if getent passwd ubuntu >/dev/null; then userdel -r ubuntu; fi \
 && if getent group  ubuntu >/dev/null; then groupdel  ubuntu; fi

# pebble (github.com/letsencrypt/pebble, an ACME test-only server) ships in
# the base image's default package set but nothing in claude-docker uses it —
# the entrypoint is tini + runuser + claude. Purging it drops a Go binary
# whose statically-linked stdlib trails current CVE fixes. Guarded so a base
# image that no longer ships it doesn't break the build.
RUN if dpkg -s pebble >/dev/null 2>&1; then apt-get purge -y pebble; fi

# NodeSource ships Node 24 LTS pinned to upstream releases — Ubuntu's archive
# `nodejs` tracks an older minor and isn't LTS-pinned. `nodistro` is
# NodeSource's distro-independent codename (works on any Debian/Ubuntu).
# npm is force-upgraded past whatever NodeSource bundles: its own vendored
# tar/brace-expansion/ip-address trail their upstream fixes by one release
# each until NodeSource's nodejs package catches up — drop the extra
# install once it does.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && chmod go+r /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "nodejs=${NODE_VERSION}" \
      git \
      git-lfs \
      tmux \
      ncurses-term \
      jq \
      less \
      openssh-client \
      unzip \
 && npm install -g --ignore-scripts npm@11.19.1 \
 && git lfs install --system --skip-repo \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI (keyring fetched at build; TODO: commit the keyring to the repo)
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# Task (go-task) — the upstream apt instructions are `curl … setup.deb.sh | bash`;
# that script is inlined here instead (fetch key, write sources.list, install), so
# nothing pipes a remote script into a shell at build time. Repo, key and layout
# are exactly what setup.deb.sh produces. Cloudsmith serves one pool under every
# codename path, so $VERSION_CODENAME survives a base-image bump to a release the
# repo has no explicit dist for.
# Version-pinned via TASK_VERSION (unlike `gh` above, which floats): Cloudsmith
# keeps every published version in the pool, so pinning here does not break on the
# next upstream release the way pinning against Ubuntu's own archive would.
RUN . /etc/os-release \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://dl.cloudsmith.io/public/task/task/gpg.046FD1186CA342F0.key \
      | gpg --dearmor -o /etc/apt/keyrings/task-archive-keyring.gpg \
 && chmod go+r /etc/apt/keyrings/task-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/task-archive-keyring.gpg] https://dl.cloudsmith.io/public/task/task/deb/ubuntu ${VERSION_CODENAME} main" \
      > /etc/apt/sources.list.d/task.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends "task=${TASK_VERSION}" \
 && rm -rf /var/lib/apt/lists/*

# GitLab CLI (glab) — version + download URL + sha256 from the generated
# pins/glab.env. The URL is sourced from the fragment (not rebuilt here), so the
# pinned sha256 provably covers the exact .deb update_pins.py hashed — the two
# can't drift. COPY sits immediately before its RUN so a glab pin bump only
# rebuilds this layer and those after it, not the apt/gh layers above.
COPY pins/glab.env /tmp/glab.env
RUN . /tmp/glab.env; set -e; ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
      amd64) URL="${GLAB_DEB_URL_AMD64}"; SHA="${GLAB_DEB_SHA256_AMD64}" ;; \
      arm64) URL="${GLAB_DEB_URL_ARM64}"; SHA="${GLAB_DEB_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch for glab: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "$URL" -o /tmp/glab.deb \
 && echo "${SHA}  /tmp/glab.deb" | sha256sum -c - \
 && apt-get install -y --no-install-recommends /tmp/glab.deb \
 && rm /tmp/glab.deb /tmp/glab.env

# AWS CLI v2 — version + download URL + sha256 from the generated pins/awscli.env.
# URL sourced from the fragment so the pinned sha256 covers exactly what is
# fetched (the URL is single-sourced in update_pins.py, not rebuilt here).
COPY pins/awscli.env /tmp/awscli.env
RUN . /tmp/awscli.env; set -e; ARCH=$(uname -m); \
    case "$ARCH" in \
      x86_64)  URL="${AWSCLI_URL_X86_64}";  SHA="${AWSCLI_SHA256_X86_64}" ;; \
      aarch64) URL="${AWSCLI_URL_AARCH64}"; SHA="${AWSCLI_SHA256_AARCH64}" ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "$URL" -o /tmp/awscli.zip \
 && echo "${SHA}  /tmp/awscli.zip" | sha256sum -c - \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip /tmp/awscli.env

# uv (Astral) — pinned version + sha256 verify; uvx ships in the same archive.
# gnu variant: ubuntu is glibc; musl would silently fail at runtime.
# URL + hash pinned in pins/uv.env (not fetched from a .sha256 sidecar) so a CDN
# swap is caught at build time, and the hash provably covers the sourced URL —
# same trust model as the AWS CLI block above. ARCH still drives the path *inside*
# the archive (uv-<arch>-unknown-linux-gnu/), which is not a download URL.
COPY pins/uv.env /tmp/uv.env
RUN . /tmp/uv.env; set -e; ARCH=$(uname -m); \
    case "$ARCH" in \
      x86_64)  URL="${UV_URL_X86_64}";  SHA="${UV_SHA256_X86_64}" ;; \
      aarch64) URL="${UV_URL_AARCH64}"; SHA="${UV_SHA256_AARCH64}" ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "$URL" -o /tmp/uv.tar.gz \
 && echo "${SHA}  /tmp/uv.tar.gz" | sha256sum -c - \
 && mkdir -p /tmp/uv \
 && tar -xzf /tmp/uv.tar.gz -C /tmp/uv \
 && install -m 0755 "/tmp/uv/uv-${ARCH}-unknown-linux-gnu/uv" /usr/local/bin/uv \
 && install -m 0755 "/tmp/uv/uv-${ARCH}-unknown-linux-gnu/uvx" /usr/local/bin/uvx \
 && rm -rf /tmp/uv /tmp/uv.tar.gz /tmp/uv.env

# Go toolchain — the official tarball from go.dev, unpacked into /usr/local/go
# exactly as https://go.dev/doc/install prescribes (no apt: Ubuntu's golang-go
# tracks an older release and splits GOROOT across paths the upstream installer
# assumes are one tree).
# MANUAL pin, like NODE_VERSION above and NOT a pins/ fragment: go.dev's release
# JSON carries no publish dates, so update_pins.py cannot evaluate its soak
# window for Go — it only reminds the operator to look. 1.26.6 was tagged
# 2026-08-13, i.e. it had already cleared the 7-day soak when pinned here.
# Bump with (version + both hashes in one shot):
#   curl -fsSL 'https://go.dev/dl/?mode=json' | jq -r '.[] | select(.stable) |
#     .version, (.files[] | select(.os=="linux" and .kind=="archive" and
#     (.arch=="amd64" or .arch=="arm64")) | "  " + .arch + " " + .sha256)'
# Confirm a bump the way these two hashes were produced: download both tarballs
# and sha256sum them locally rather than trusting the JSON's advertised digest.
# Placed before the npm layer on purpose — the tarball is ~64 MB and Go moves far
# less often than the claude-code pin, so a weekly claude-code bump does not
# re-download it.
ARG GO_VERSION=1.26.6
ARG GO_SHA256_AMD64=708effb774be8237570d0add163225abbdfaf4fca28b2611df167beba4feef89
ARG GO_SHA256_ARM64=d0507e9e9d7fe012aae570108cbd76c15de879e17130ab8cb90d4d7445cb1f2e
RUN ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
      amd64) SHA="${GO_SHA256_AMD64}" ;; \
      arm64) SHA="${GO_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch for go: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-${ARCH}.tar.gz" -o /tmp/go.tar.gz \
 && echo "${SHA}  /tmp/go.tar.gz" | sha256sum -c - \
 && tar -C /usr/local -xzf /tmp/go.tar.gz \
 && rm /tmp/go.tar.gz \
 && /usr/local/go/bin/go version

# npm-backed CLIs — pinned versions. Trust = npm's signed dist.integrity;
# run `npm audit signatures <pkg>@<ver>` when bumping.
# --ignore-scripts blocks lifecycle hooks for every package + transitive dep
# (hard security boundary, kept on). claude-code 2.1.x ships its real binary
# in a per-arch optional-dep package; the launcher's postinstall (install.cjs)
# copies it over bin/claude.exe. Without it `claude` is a stub that errors at
# exec. We invoke that one script ourselves — platform-detect + file copy,
# no network/exec, audit-verified for 2.1.131; re-read on each bump.
# `npm root -g` over a hardcoded path so we don't break on a different prefix.
# npm tools carry version-only pins (no sha256): npm install verifies the
# registry-advertised dist.integrity (registry-integrity, not provenance; CI
# runs `npm audit signatures`). All three share this layer, so they share a COPY.
COPY pins/claude-code.env pins/openspec.env pins/pnpm.env /tmp/
RUN . /tmp/claude-code.env && . /tmp/openspec.env && . /tmp/pnpm.env \
 && npm install -g --ignore-scripts \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@fission-ai/openspec@${OPENSPEC_VERSION}" \
      "pnpm@${PNPM_VERSION}" \
 && node "$(npm root -g)/@anthropic-ai/claude-code/install.cjs" \
 && rm /tmp/claude-code.env /tmp/openspec.env /tmp/pnpm.env

# tfenv — pure-bash terraform version manager. Arch-independent (just
# bash scripts), so a single sha256 covers amd64 and arm64. We deliberately
# ship NO terraform binary; the project's `.terraform-version` (or an
# interactive `tfenv install <v>`) fetches the right version from
# releases.hashicorp.com at runtime, in the same runtime-fetch class as
# `pnpm dlx`/`uvx`. Installed under /opt (not /root) so image-level
# version bumps aren't shadowed by the claude-code-root named volume.
# Placed after the heavier npm install so a tfenv version bump doesn't
# invalidate that layer's cache (tfenv pins move far less often than the
# claude-code/openspec/pnpm pins above).
COPY pins/tfenv.env /tmp/tfenv.env
RUN . /tmp/tfenv.env \
 && curl -fsSL "$TFENV_URL" -o /tmp/tfenv.tar.gz \
 && echo "${TFENV_SHA256}  /tmp/tfenv.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/tfenv \
 && tar -xzf /tmp/tfenv.tar.gz -C /opt/tfenv --strip-components=1 \
 && ln -s /opt/tfenv/bin/tfenv /usr/local/bin/tfenv \
 && ln -s /opt/tfenv/bin/terraform /usr/local/bin/terraform \
 && rm /tmp/tfenv.tar.gz /tmp/tfenv.env

# Plain `tmux` mode swallows Shift+Enter so Claude's prompt sees only Enter,
# forcing users to type `\` for a literal newline. `always` is required
# (not `on`) because Claude does not send the kitty activation request that
# `on` waits for — see claude-code#26629. /etc/tmux.conf, not
# /root/.tmux.conf, because /root is masked by the claude-code-root named
# volume at runtime. Harmless under tmux -CC: iTerm2 control mode bypasses
# tmux's input layer. Placed after npm install so edits don't invalidate
# the heavy AWS CLI / uv / glab / npm download layers above.
RUN cat > /etc/tmux.conf <<'EOF'
set -s extended-keys always
set -as terminal-features "*:extkeys"
EOF

# Go environment. Spelled with a literal /root rather than ${HOME}: Docker does
# not define HOME during the build, so "${HOME}/go" would expand to "/go". /root
# is correct for both paths through the entrypoint — the legacy root fallback,
# and the dropped-privilege user, whose passwd entry is created with -d /root.
# GOROOT is already baked into the go.dev tarball; set explicitly so scripts that
# read the variable directly (rather than `go env GOROOT`) see it too.
# GOBIN is spelled out rather than written as ${GOPATH}/bin for the same class of
# reason: Docker resolves a variable against the value from *before* the current
# instruction, so ${GOPATH}/bin inside this ENV would yield "/bin".
ENV GOBIN=/root/go/bin \
    GOPATH=/root/go \
    GOROOT=/usr/local/go

# DISABLE_AUTOUPDATER=1 keeps the pinned CLAUDE_CODE_VERSION authoritative —
# without it, claude auto-replaces itself at runtime, defeating the
# --ignore-scripts supply-chain pinning above. Bump the image to upgrade.
# No TASK_X_REMOTE_TASKFILES here: go-task's `includes:` from a remote URL left
# experimental in 3.53.1, so the feature is on by default and setting the opt-in
# makes every `task` invocation warn that the experiment is released. It stays a
# runtime code-fetch primitive in the same class as `pnpm dlx`/`uvx`/`go install`;
# task still prompts before trusting a new remote Taskfile checksum.
# PATH: /usr/local/go/bin comes first — the go.dev-prescribed entry for the
# toolchain, ahead of the system paths so the image's pinned Go wins.
# /root/.local/bin (the pip --user / `uv tool install` prefix) and /root/go/bin
# (the GOPATH default, where `go install` writes) are appended LAST on purpose:
# both live in the persistent claude-code-root volume and are writable by the
# session, so a binary one session drops there must never be able to shadow a
# system binary (git, gh, aws, …) on a later run. Tools installed into either
# stay runnable by name; only deliberate overrides are given up.
ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
    DISABLE_AUTOUPDATER=1 \
    IS_SANDBOX=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH="/usr/local/go/bin:${PATH}:/root/.local/bin:/root/go/bin"

# Container starts as root so the entrypoint can chown /root to the host
# UID, then drops privileges via runuser. Steady-state, claude runs as the
# host user with no effective / permitted / ambient capabilities — the
# kernel clears those on the UID→non-zero transition; the bounding set
# retains the setup caps but is inert under `no-new-privileges`. Do not
# add a `USER` directive here: the entrypoint expects to start as root so
# it can perform the chown.
# See entrypoint.sh and run.sh's --cap-add lines for the full picture.

WORKDIR /workspaces

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
