# Pinned base image (digest pins all arches via the multi-arch index).
# Bump with: docker buildx imagetools inspect node:20-bookworm-slim --format '{{.Manifest.Digest}}'
FROM node:20-bookworm-slim@sha256:f93745c153377ee2fbbdd6e24efcd03cd2e86d6ab1d8aa9916a3790c40313a55

# Override versions at build time: docker build --build-arg CLAUDE_CODE_VERSION=x.y.z ...
ARG CLAUDE_CODE_VERSION=2.1.112
ARG GLAB_VERSION=1.92.1
ARG GLAB_DEB_SHA256_AMD64=18048e5cb2cbc92eb31d4190852c6da32f6713633cfefc7b3fe00c18806c4f53
ARG GLAB_DEB_SHA256_ARM64=f12a5e5e820b4c0b2803de4136884a90a64918bc3c7fd309f8c5a3ca9455fa8b
ARG AWSCLI_VERSION=2.34.31
ARG AWSCLI_SHA256_X86_64=d1540db414d48650c87cea7e2b585368b864d2be5fc4034f9af3b1e3dc2f678a
ARG AWSCLI_SHA256_AARCH64=932ff651397d5c56f78987fcdf736dfc62c2a32ed2c0e9c9ae96e9a7ff1e85ea

RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    tmux \
    ca-certificates \
    curl \
    jq \
    less \
    openssh-client \
    gnupg \
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

# claude-code — pinned version, no lifecycle scripts
RUN npm install -g --ignore-scripts "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 \
    IS_SANDBOX=1

# Container runs as root by design: IS_SANDBOX=1 + --cap-drop ALL + no-new-privileges
# make the container itself the security boundary. Do not add a USER directive
# without reworking the host-config bind-mount layout.

WORKDIR /workspaces

CMD ["claude"]
