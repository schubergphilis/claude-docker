# Pinned base image (digest pins all arches via the multi-arch index).
# Bump with: docker buildx imagetools inspect ubuntu:26.04 --format '{{.Manifest.Digest}}'
# Ubuntu (not Debian): only ubuntu:26.04 ships git ≥ 2.48 in its main archive,
# needed for the `extensions.relativeWorktrees` repo extension. Rationale and
# alternatives in openspec/changes/worktree-relative-paths/design.md.
FROM ubuntu:26.04@sha256:5e275723f82c67e387ba9e3c24baa0abdcb268917f276a0561c97bef9450d0b4

# pipefail propagates failures in RUN ... | ... — without this, a failed curl
# into tee/sha256sum silently succeeds and the build continues with bad data.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]

# When bumping a version ARG, also refresh any paired sha256 ARG in the same commit.
# NODE_VERSION format is NodeSource's: <upstream>-1nodesource1.
# Bump with: curl -fsSL https://deb.nodesource.com/node_20.x/dists/nodistro/main/binary-amd64/Packages.gz | gunzip | grep -E '^(Package|Version):' | head -4
ARG NODE_VERSION=20.20.2-1nodesource1
ARG CLAUDE_CODE_VERSION=2.1.112
ARG OPENSPEC_VERSION=1.3.0
ARG PNPM_VERSION=10.33.2
ARG GLAB_VERSION=1.92.1
ARG GLAB_DEB_SHA256_AMD64=18048e5cb2cbc92eb31d4190852c6da32f6713633cfefc7b3fe00c18806c4f53
ARG GLAB_DEB_SHA256_ARM64=f12a5e5e820b4c0b2803de4136884a90a64918bc3c7fd309f8c5a3ca9455fa8b
ARG AWSCLI_VERSION=2.34.31
ARG AWSCLI_SHA256_X86_64=d1540db414d48650c87cea7e2b585368b864d2be5fc4034f9af3b1e3dc2f678a
ARG AWSCLI_SHA256_AARCH64=932ff651397d5c56f78987fcdf736dfc62c2a32ed2c0e9c9ae96e9a7ff1e85ea
ARG UV_VERSION=0.11.8
ARG UV_SHA256_X86_64=56dd1b66701ecb62fe896abb919444e4b83c5e8645cca953e6ddd496ff8a0feb
ARG UV_SHA256_AARCH64=eee8dd658d20e5ac85fec9c2326b6cbc9d83a1eef09ef07433e58698ac849591
ARG TFENV_VERSION=3.0.0
ARG TFENV_SHA256=463132e45a211fa3faf85e62fdfaa9bb746343ff1954ccbad91cae743df3b648

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

# NodeSource ships Node 20 LTS pinned to upstream releases — Ubuntu's archive
# `nodejs` tracks an older minor and isn't LTS-pinned. `nodistro` is
# NodeSource's distro-independent codename (works on any Debian/Ubuntu).
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg \
 && install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
      | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
 && chmod go+r /etc/apt/keyrings/nodesource.gpg \
 && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_20.x nodistro main" \
      > /etc/apt/sources.list.d/nodesource.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      "nodejs=${NODE_VERSION}" \
      git \
      tmux \
      ncurses-term \
      jq \
      less \
      openssh-client \
      unzip \
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

# GitLab CLI (glab) — pinned version + sha256 verify
RUN ARCH=$(dpkg --print-architecture); \
    case "$ARCH" in \
      amd64) SHA="${GLAB_DEB_SHA256_AMD64}" ;; \
      arm64) SHA="${GLAB_DEB_SHA256_ARM64}" ;; \
      *) echo "Unsupported arch for glab: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${ARCH}.deb" \
      -o /tmp/glab.deb \
 && echo "${SHA}  /tmp/glab.deb" | sha256sum -c - \
 && apt-get install -y --no-install-recommends /tmp/glab.deb \
 && rm /tmp/glab.deb

# AWS CLI v2 — pinned version + sha256 verify
RUN set -e; ARCH=$(uname -m); \
    case "$ARCH" in \
      x86_64)  SHA="${AWSCLI_SHA256_X86_64}" ;; \
      aarch64) SHA="${AWSCLI_SHA256_AARCH64}" ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${ARCH}-${AWSCLI_VERSION}.zip" -o /tmp/awscli.zip \
 && echo "${SHA}  /tmp/awscli.zip" | sha256sum -c - \
 && unzip -q /tmp/awscli.zip -d /tmp \
 && /tmp/aws/install \
 && rm -rf /tmp/aws /tmp/awscli.zip

# uv (Astral) — pinned version + sha256 verify; uvx ships in the same archive.
# gnu variant: ubuntu is glibc; musl would silently fail at runtime.
# Hash pinned in ARG (not fetched from .sha256 sidecar) so a CDN swap is caught
# at build time — same trust model as the AWS CLI block above.
RUN set -e; ARCH=$(uname -m); \
    case "$ARCH" in \
      x86_64)  SHA="${UV_SHA256_X86_64}" ;; \
      aarch64) SHA="${UV_SHA256_AARCH64}" ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/astral-sh/uv/releases/download/${UV_VERSION}/uv-${ARCH}-unknown-linux-gnu.tar.gz" \
      -o /tmp/uv.tar.gz \
 && echo "${SHA}  /tmp/uv.tar.gz" | sha256sum -c - \
 && mkdir -p /tmp/uv \
 && tar -xzf /tmp/uv.tar.gz -C /tmp/uv \
 && install -m 0755 "/tmp/uv/uv-${ARCH}-unknown-linux-gnu/uv" /usr/local/bin/uv \
 && install -m 0755 "/tmp/uv/uv-${ARCH}-unknown-linux-gnu/uvx" /usr/local/bin/uvx \
 && rm -rf /tmp/uv /tmp/uv.tar.gz

# npm-backed CLIs — pinned versions, no lifecycle scripts
RUN npm install -g --ignore-scripts \
      "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" \
      "@fission-ai/openspec@${OPENSPEC_VERSION}" \
      "pnpm@${PNPM_VERSION}"

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
RUN curl -fsSL "https://github.com/tfutils/tfenv/archive/refs/tags/v${TFENV_VERSION}.tar.gz" \
      -o /tmp/tfenv.tar.gz \
 && echo "${TFENV_SHA256}  /tmp/tfenv.tar.gz" | sha256sum -c - \
 && mkdir -p /opt/tfenv \
 && tar -xzf /tmp/tfenv.tar.gz -C /opt/tfenv --strip-components=1 \
 && ln -s /opt/tfenv/bin/tfenv /usr/local/bin/tfenv \
 && ln -s /opt/tfenv/bin/terraform /usr/local/bin/terraform \
 && rm /tmp/tfenv.tar.gz

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

ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
    IS_SANDBOX=1 \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8

# Container runs as root by design: IS_SANDBOX=1 + --cap-drop ALL + no-new-privileges
# make the container itself the security boundary. Do not add a USER directive
# without reworking the host-config bind-mount layout.

WORKDIR /workspaces

CMD ["claude"]
