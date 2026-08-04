# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# Pinned base image (digest pins all arches via the multi-arch index).
# Bump with: docker buildx imagetools inspect ubuntu:26.04 --format '{{.Manifest.Digest}}'
# Ubuntu (not Debian): only ubuntu:26.04 ships git ≥ 2.48 in its main archive,
# needed for the `extensions.relativeWorktrees` repo extension. Rationale and
# alternatives in openspec/changes/worktree-relative-paths/design.md.
#
# NODE_VERSION is declared before the first FROM so both stages can inherit it
# with a bare `ARG NODE_VERSION` redeclaration (Docker's global-ARG pattern).

# nodejs stays a MANUAL pin: NodeSource's apt repo is signed, and its publish
# dates aren't cleanly machine-readable for the soak, so update_pins.py leaves
# it alone and only reminds the operator to check it.
# NODE_VERSION format is NodeSource's: <upstream>-1nodesource1.
# Bump with: curl -fsSL https://deb.nodesource.com/node_24.x/dists/nodistro/main/binary-amd64/Packages.gz | gunzip | grep -E '^(Package|Version):' | head -4
ARG NODE_VERSION=24.17.0-1nodesource1

# ── installer ────────────────────────────────────────────────────────────────
# Has curl, gnupg, unzip, and all apt repository infrastructure needed to
# download and verify every tool. None of this leaks into the runtime image.
FROM ubuntu:26.04@sha256:5e275723f82c67e387ba9e3c24baa0abdcb268917f276a0561c97bef9450d0b4 AS installer

ARG NODE_VERSION

# pipefail propagates failures in RUN ... | ... — without this, a failed curl
# into tee/sha256sum silently succeeds and the build continues with bad data.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

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

# Install build-time deps and set up NodeSource; nodejs is needed in the
# installer stage for `npm install -g` and for running install.cjs.
# unzip is used only for the AWS CLI installer and does not reach the runtime image.
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg unzip \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && chmod go+r /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "nodejs=${NODE_VERSION}" \
      git-lfs \
 && git lfs install --system --skip-repo \
 && rm -rf /var/lib/apt/lists/*

# GitHub CLI — binary installed here; the dearmored keyring is copied to the
# runtime stage so it can install nodejs from NodeSource without needing gnupg.
# The GitHub CLI apt repo is not reproduced in the runtime stage: gh is a
# self-contained Go binary and is copied directly.
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# GitLab CLI (glab) — self-contained Go binary; copied to runtime directly.
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
 && rm /tmp/glab.deb /tmp/glab.env \
 && rm -rf /var/lib/apt/lists/*

# AWS CLI v2 — installs to /usr/local/aws-cli with symlinks in /usr/local/bin.
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

# uv (Astral) — gnu variant; binaries installed to /usr/local/bin.
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

# npm-backed CLIs — installed to a dedicated prefix (/opt/npm-global) so the
# COPY into the runtime stage is a single predictable directory, independent of
# the NodeSource npm prefix convention. The runtime stage adds the bin dir to
# PATH. install.cjs is invoked manually (--ignore-scripts blocks it) to copy
# the arch-specific claude binary; it reads its own location via npm root -g
# so it works correctly with the custom prefix.
COPY pins/claude-code.env pins/openspec.env pins/pnpm.env /tmp/
RUN mkdir -p /opt/npm-global \
 && NPM_CONFIG_PREFIX=/opt/npm-global \
    . /tmp/claude-code.env && . /tmp/openspec.env && . /tmp/pnpm.env \
 && NPM_CONFIG_PREFIX=/opt/npm-global npm install -g --ignore-scripts \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@fission-ai/openspec@${OPENSPEC_VERSION}" \
      "pnpm@${PNPM_VERSION}" \
 && NPM_CONFIG_PREFIX=/opt/npm-global node \
      "$(NPM_CONFIG_PREFIX=/opt/npm-global npm root -g)/@anthropic-ai/claude-code/install.cjs" \
 && rm /tmp/claude-code.env /tmp/openspec.env /tmp/pnpm.env

# tfenv — pure-bash terraform version manager. Arch-independent (just
# bash scripts), so a single sha256 covers amd64 and arm64. We deliberately
# ship NO terraform binary; the project's `.terraform-version` (or an
# interactive `tfenv install <v>`) fetches the right version from
# releases.hashicorp.com at runtime, in the same runtime-fetch class as
# `pnpm dlx`/`uvx`. Installed under /opt (not /root) so image-level
# version bumps aren't shadowed by the claude-code-root named volume.
COPY pins/tfenv.env /tmp/tfenv.env
RUN . /tmp/tfenv.env \
 && curl -fsSL "$TFENV_URL" -o /tmp/tfenv.tar.gz \
 && echo "${TFENV_SHA256}  /tmp/tfenv.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/tfenv \
 && tar -xzf /tmp/tfenv.tar.gz -C /opt/tfenv --strip-components=1 \
 && rm /tmp/tfenv.tar.gz /tmp/tfenv.env


# ── runtime ───────────────────────────────────────────────────────────────────
# Fresh base: only runtime-needed packages installed via apt. No gnupg, no
# unzip, no GitHub CLI apt repo. NodeSource keyring is copied from the
# installer stage — this stage never needs gnupg. gh and glab are copied as
# self-contained binaries. All other tools are copied from the installer stage.
FROM ubuntu:26.04@sha256:5e275723f82c67e387ba9e3c24baa0abdcb268917f276a0561c97bef9450d0b4

ARG NODE_VERSION

SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

RUN echo 'APT::Sandbox::User "root";' > /etc/apt/apt.conf.d/10no-sandbox \
 && chown root:root /var/cache/apt/archives/partial

RUN if getent passwd ubuntu >/dev/null; then userdel -r ubuntu; fi \
 && if getent group  ubuntu >/dev/null; then groupdel  ubuntu; fi

# Bake a non-root `claude` user at a fixed UID/GID (999) so the entrypoint
# has a safe default to fall back to when HOST_UID is unset or 0 (e.g. plain
# `docker run` without -e HOST_UID). HOME=/root is deliberate: the persistent
# named volumes for claude-code state are mounted there and must stay at that
# path. UID 999 is below Ubuntu's default UID_MIN (1000) so it won't collide
# with a host user forwarded via HOST_UID on typical Linux or macOS systems.
RUN groupadd -g 999 claude \
 && useradd -u 999 -g 999 -d /root -s /bin/bash -M -N claude

# NodeSource keyring was dearmored in the installer stage — copy it here to
# avoid needing gnupg in the runtime image. No GitHub CLI repo: gh is copied
# as a binary below.
COPY --from=installer /etc/apt/keyrings/nodesource.gpg /etc/apt/keyrings/nodesource.gpg

# NodeSource ships Node 24 LTS pinned to upstream releases — Ubuntu's archive
# `nodejs` tracks an older minor and isn't LTS-pinned. `nodistro` is
# NodeSource's distro-independent codename (works on any Debian/Ubuntu).
RUN chmod go+r /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_24.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates \
      curl \
      "nodejs=${NODE_VERSION}" \
      git \
      git-lfs \
      tmux \
      ncurses-term \
      jq \
      less \
      openssh-client \
 && git lfs install --system --skip-repo \
 && rm -rf /var/lib/apt/lists/*

# gh and glab: self-contained Go binaries — no apt repo infrastructure needed.
COPY --from=installer /usr/bin/gh   /usr/bin/gh
COPY --from=installer /usr/bin/glab /usr/bin/glab

# AWS CLI
COPY --from=installer /usr/local/aws-cli          /usr/local/aws-cli
COPY --from=installer /usr/local/bin/aws           /usr/local/bin/aws
COPY --from=installer /usr/local/bin/aws_completer /usr/local/bin/aws_completer

# uv / uvx
COPY --from=installer /usr/local/bin/uv  /usr/local/bin/uv
COPY --from=installer /usr/local/bin/uvx /usr/local/bin/uvx

# npm globals (claude-code, openspec, pnpm) — the whole prefix directory,
# which contains lib/node_modules/ and bin/. PATH is extended below.
COPY --from=installer /opt/npm-global /opt/npm-global

# tfenv — installed under /opt (not /root) so image-level version bumps aren't
# shadowed by the claude-code-root named volume at runtime.
COPY --from=installer /opt/tfenv /opt/tfenv
RUN ln -s /opt/tfenv/bin/tfenv     /usr/local/bin/tfenv \
 && ln -s /opt/tfenv/bin/terraform /usr/local/bin/terraform

# Plain `tmux` mode swallows Shift+Enter so Claude's prompt sees only Enter,
# forcing users to type `\` for a literal newline. `always` is required
# (not `on`) because Claude does not send the kitty activation request that
# `on` waits for — see claude-code#26629. /etc/tmux.conf, not
# /root/.tmux.conf, because /root is masked by the claude-code-root named
# volume at runtime. Harmless under tmux -CC: iTerm2 control mode bypasses
# tmux's input layer.
RUN cat > /etc/tmux.conf <<'EOF'
set -s extended-keys always
set -as terminal-features "*:extkeys"
EOF

# DISABLE_AUTOUPDATER=1 keeps the pinned CLAUDE_CODE_VERSION authoritative —
# without it, claude auto-replaces itself at runtime, defeating the
# --ignore-scripts supply-chain pinning above. Bump the image to upgrade.
ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
    DISABLE_AUTOUPDATER=1 \
    IS_SANDBOX=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    PATH="/opt/npm-global/bin:${PATH}"

# Container starts as root so the entrypoint can chown /root to the host
# UID, then drops privileges via runuser. Steady-state, claude runs as the
# host user (or the baked-in UID 999 `claude` user when HOST_UID is unset)
# with no effective / permitted / ambient capabilities — the kernel clears
# those on the UID→non-zero transition; the bounding set retains the setup
# caps but is inert under `no-new-privileges`. No USER directive: the
# entrypoint must start as root to perform the chown and useradd steps.
# See entrypoint.sh and run.sh's --cap-add lines for the full picture.

WORKDIR /workspaces

COPY --chmod=0755 entrypoint.sh /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["claude"]
