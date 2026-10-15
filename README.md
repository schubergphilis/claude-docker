# claude-docker

[![GitHub release](https://img.shields.io/github/v/release/schubergphilis/claude-docker)](https://github.com/schubergphilis/claude-docker/releases)
[![License](https://img.shields.io/github/license/schubergphilis/claude-docker)](LICENSE)

<img src="./assets/logos/claude-docker.png" alt="claude-docker logo" width="250">

Run Claude Code in a container that inherits your setup but not your filesystem. Workspace access is scoped to the directories you pass in; your statusline, skills, agents, and slash commands ride along as read-only bind-mounts. CLI tools are preinstalled (`gh`, `glab`, `aws`, `az` with the `azure-devops` extension, `openspec`, `uv`, `pnpm`, `tfenv`, `git-lfs`, `task`) plus a version-pinned Go toolchain (`go`) — other language runtimes are not: `tfenv` and `uv` fetch your project-pinned Terraform / Python on demand. Host credentials (`gh`, `glab`, `aws`, `tfe`, `az`) are opt-in per flag; nothing leaks in by default.

The VCS and cloud CLIs (`gh`, `glab`, `aws`, `az`) need a flag to see host credentials — see [Credential opt-in](docs/auth.md#credential-opt-in). The rest work out of the box.

## Quickstart

```bash
# Build the image from your checkout (one-time; rerun after Dockerfile or tool pins change)
docker build -t claude-code:local .

# Put on your PATH (create ~/bin if it doesn't exist)
mkdir -p ~/bin
ln -s "$(pwd)/run.sh" ~/bin/claude-docker
```

Then run it against a workspace:

```bash
claude-docker ~/repo
```

The build needs BuildKit — on a Homebrew `docker` CLI with Colima, see [BuildKit on Colima](docs/installation.md#buildkit-on-colima) first. On podman, see [Container runtime](docs/usage.md#container-runtime).

### Prebuilt image

Building from your checkout stays fully supported, and `run.sh` still defaults to `claude-code:local`. Released versions are also published to `ghcr.io/schubergphilis/claude-docker` for `linux/amd64` and `linux/arm64`; point the wrapper at one with the `CLAUDE_DOCKER_IMAGE` override:

```bash
docker pull ghcr.io/schubergphilis/claude-docker:v0.1.0
export CLAUDE_DOCKER_IMAGE=ghcr.io/schubergphilis/claude-docker:v0.1.0
```

Pin the full `v`-prefixed tag — there is no `latest` and no `:0.1`. Only `linux/amd64` passes the publish pipeline's dockle, dive and grype scans; `linux/arm64` is published without them. See [Prebuilt image from GHCR](docs/installation.md#prebuilt-image-from-ghcr) for release candidates and the scan-coverage detail.

## Documentation

- [Installation](docs/installation.md) — BuildKit on Colima, prebuilt image from GHCR
- [Usage](docs/usage.md) — container runtime, session flags, resuming sessions, host config parity, worktrees, split panes, extending the image
- [Auth model](docs/auth.md) — credential opt-in flags, AWS SSO, GitHub auth proxy, Terraform Cloud, private registries, custom model endpoint, Azure DevOps Server CA
- [Security](docs/security.md) — threat model, image vulnerability scanning
- [Maintenance](docs/maintenance.md) — updating pinned tool versions, CI smoke tests
- [Windows](docs/windows.md) — PowerShell, WSL2 and Git Bash hosts
- [Scope](docs/scope.md) — what claude-docker deliberately does not do

Behavioural requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).

## License

Licensed under the Apache License, Version 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The software is provided on an **"AS IS" basis, without warranties or conditions of any kind**, express or implied, including any warranty as to its **security, fitness, or suitability** for a particular purpose. The container narrows blast radius but is **not** a full sandbox (see [Threat model](docs/security.md#threat-model)) — you are responsible for assessing whether it meets your own security requirements before use. claude-docker installs and runs third-party software under its own license and is not affiliated with or endorsed by Anthropic.
