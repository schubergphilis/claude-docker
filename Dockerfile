FROM node:20-bookworm-slim

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

# GitHub CLI
RUN install -d -m 0755 /etc/apt/keyrings \
 && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null \
 && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
 && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends gh \
 && rm -rf /var/lib/apt/lists/*

# GitLab CLI (glab) — latest release deb from GitLab API
RUN ARCH=$(dpkg --print-architecture) \
 && VERSION=$(curl -fsSL "https://gitlab.com/api/v4/projects/34675721/releases" \
      | jq -r '.[0].tag_name' | sed 's/^v//') \
 && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${VERSION}/downloads/glab_${VERSION}_linux_${ARCH}.deb" \
      -o /tmp/glab.deb \
 && apt-get install -y --no-install-recommends /tmp/glab.deb \
 && rm /tmp/glab.deb

# AWS CLI v2
RUN set -e; ARCH=$(uname -m); \
    case "$ARCH" in \
      x86_64)  URL="https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" ;; \
      aarch64) URL="https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" ;; \
      *) echo "Unsupported arch: $ARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "$URL" -o /tmp/awscli.zip \
    && unzip -q /tmp/awscli.zip -d /tmp \
    && /tmp/aws/install \
    && rm -rf /tmp/aws /tmp/awscli.zip

RUN npm install -g @anthropic-ai/claude-code

ENV CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1

WORKDIR /workspaces

CMD ["claude"]
