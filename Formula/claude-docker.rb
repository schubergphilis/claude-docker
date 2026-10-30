# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis

# This repository is its own tap:
#   brew tap schubergphilis/claude-docker https://github.com/schubergphilis/claude-docker
# url and sha256 always name the latest stable release, which this file
# cannot be part of; .github/workflows/homebrew.yml moves them after each one.
class ClaudeDocker < Formula
  desc "Hardened Docker wrapper for Claude Code"
  homepage "https://github.com/schubergphilis/claude-docker"
  url "https://github.com/schubergphilis/claude-docker/archive/refs/tags/v1.1.0.tar.gz"
  sha256 "d86a9441cd1e486e0f5faeb6db971eaac89f5b3b139ffef75c99dd3d34767be7"
  license "Apache-2.0"

  livecheck do
    url :stable
    strategy :github_latest
  end

  def install
    libexec.install "run.sh"
    # Default to the image published for this version, so the wrapper and the
    # image it runs move together. A CLAUDE_DOCKER_IMAGE the user set wins.
    (bin/"claude-docker").write <<~SH
      #!/bin/bash
      export CLAUDE_DOCKER_IMAGE="${CLAUDE_DOCKER_IMAGE:-ghcr.io/schubergphilis/claude-docker:v#{version}}"
      exec "#{libexec}/run.sh" "$@"
    SH
  end

  def caveats
    <<~EOS
      claude-docker needs a container runtime: Docker Desktop, Colima or Podman.
      The first run pulls ghcr.io/schubergphilis/claude-docker:v#{version}.
      Set CLAUDE_DOCKER_IMAGE to run another image, e.g. a local build.
    EOS
  end

  test do
    assert_match "Usage: claude-docker", shell_output("#{bin}/claude-docker --help")
  end
end
