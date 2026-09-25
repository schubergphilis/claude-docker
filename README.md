# claude-docker

[![GitHub release](https://img.shields.io/github/v/release/schubergphilis/claude-docker)](https://github.com/schubergphilis/claude-docker/releases)
[![License](https://img.shields.io/github/license/schubergphilis/claude-docker)](LICENSE)

<img src="./assets/logos/claude-docker.png" width="250"></a>

Run Claude Code in a container that inherits your setup but not your filesystem. Workspace access is scoped to the directories you pass in; your statusline, skills, agents, and slash commands ride along as read-only bind-mounts. CLI tools are preinstalled (`gh`, `glab`, `aws`, `openspec`, `uv`, `pnpm`, `tfenv`, `git-lfs`, `task`) plus a version-pinned Go toolchain (`go`) — other language runtimes are not: `tfenv` and `uv` fetch your project-pinned Terraform / Python on demand. Host credentials (`gh`, `glab`, `aws`, `tfe`) are opt-in per flag; nothing leaks in by default.

The VCS and cloud CLIs (`gh`, `glab`, `aws`) need a flag to see host credentials — see [Credential opt-in](#credential-opt-in). The rest work out of the box.

## Install

```bash
# Build the image from your checkout (one-time; rerun after Dockerfile or tool pins change)
docker build -t claude-code:local .

# Put on your PATH (create ~/bin if it doesn't exist)
mkdir -p ~/bin
ln -s "$(pwd)/run.sh" ~/bin/claude-docker
```

The build needs BuildKit (the Dockerfile uses `COPY --chmod`). Docker Desktop ships it by default. A Homebrew `docker` CLI with Colima does **not**: the buildx plugin is a separate formula, and without it `docker build` silently falls back to the legacy builder and dies at the `COPY --chmod` step with `the --chmod option requires BuildKit`. One-time fix:

```bash
brew install docker-buildx
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
```

Verify with `docker buildx version`, then rerun the same `docker build` — with the plugin present, plain `docker build` uses BuildKit automatically.

### Prebuilt image from GHCR

Released versions are published to `ghcr.io/schubergphilis/claude-docker`, so you can skip the build:

```bash
docker pull ghcr.io/schubergphilis/claude-docker:v0.1.0
export CLAUDE_DOCKER_IMAGE=ghcr.io/schubergphilis/claude-docker:v0.1.0
```

`CLAUDE_DOCKER_IMAGE` is the existing image override ([Extending the image](docs/workflows.md#extending-the-image) uses the same variable); `run.sh` still defaults to `claude-code:local`, and building from your checkout stays fully supported. Pin whichever you use — an image and the `run.sh` beside it are not independently versioned.

**Pin the full `v`-prefixed tag.** A `v0.1.0` tag publishes exactly `:v0.1.0` — there is no `latest`, no `:0.1`, and no semver expansion. The publishing action forces `flavor: latest=false` on `docker/metadata-action`'s default `type=ref` tagging and exposes no input to change either.

**Release candidates are published too, and are not supported.** The `v*` trigger does not distinguish a candidate from a release, so pre-release tags such as `v0.1.0-rc.6` are built, scanned and pushed exactly like a stable one — several are public right now. They exist so a candidate can be pulled and checked against the registry before a release is committed to, and because tagging is `type=ref` with no `latest`, an RC can never move or shadow a stable tag. Use them only if you cut them: if you hit a bug on one, retry against the latest stable tag and report it there — an RC is never fixed in place.

**Architectures.** The manifest list covers `linux/amd64` and `linux/arm64`, so Apple Silicon and arm64 Colima hosts get a native image rather than an emulated one — the same set the Dockerfile already supports, since every third-party download in it branches on the build architecture against per-arch pins.

**Scan coverage is not symmetric, and you should know which half you're getting.** The publish pipeline lints with hadolint and dockle and scans with dive and grype, but only one architecture reaches those tools: the action loads a single image into the local docker store and prefers whichever platform the runner provides natively, which is `linux/amd64`. So **`linux/arm64` is built and published without passing dockle, dive or grype.** Both images come from one Dockerfile and one set of pins, and the findings that drive the suppressions in [`.grype.yaml`](.grype.yaml) are vendored-code findings that reproduce identically on both — but the gap is real and is recorded here rather than implied away. `ci.yml`'s Trivy gate and the weekly [image scan](docs/security.md#image-vulnerability-scanning) are likewise amd64-only.

Because that scan runs *before* the push, **a `v*` tag whose pipeline run goes red publishes nothing.** If a tag exists here with no package behind it, check the Docker workflow run for that tag before assuming a registry problem.

## Container runtime

`claude-docker` runs on **docker or podman**. With no configuration it auto-detects the engine, preferring `docker` and falling back to `podman` — so a podman-only host (including Windows via `podman machine` + WSL backend, and podman-as-docker Linux setups) works with zero setup and never hits `docker: command not found`.

To force an engine, set `CLAUDE_DOCKER_RUNTIME`:

```bash
CLAUDE_DOCKER_RUNTIME=podman claude-docker ~/repo
```

The env var is the canonical mechanism: it works everywhere — scripts, CI, editor "run" integrations, and non-interactive shells all inherit it. If you want a shorter interactive spelling, an alias is optional sugar (not a substitute — an alias only resolves at an interactive prompt, so scripts and editors still need the env var):

```bash
alias claude-podman='CLAUDE_DOCKER_RUNTIME=podman claude-docker'
```

Only `docker` and `podman` are accepted; any other value is rejected before anything runs. The image build is the engine's own command — `podman build -t claude-code:local .` on a podman host, mirroring the `docker build` line above.

**Windows / Git Bash:** run `claude-docker` from Git Bash (MSYS/MINGW). The wrapper disables MSYS's automatic POSIX→Windows path rewriting for the engine's argv and translates host mount paths itself, so container-side paths reach `podman.exe`/`docker.exe` intact — no more `invalid option type "\Program Files\Git\workspaces\..."`.

## Usage

```bash
claude-docker                             # current dir as workspace
claude-docker ~/repo-a ~/repo-b           # multi-workspace
claude-docker --yolo ~/repo               # alias for --dangerously-skip-permissions
claude-docker ~/repo -- --resume          # any claude flag after --
```

`claude-docker --help` (or `-h`) prints every wrapper flag with a one-line explanation — the canonical reference.

### Credential opt-in

**Credentials are off by default.** No AWS / GitHub / GitLab / Terraform Cloud / package-registry config, tokens, or env vars reach the container unless you explicitly opt in:

| Flag          | Effect                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                |
| ------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--aws`       | Mount `~/.aws/config` and `~/.aws/sso/` read-only and forward `AWS_PROFILE` / `AWS_REGION` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`. `~/.aws/credentials` (long-lived keys) and `~/.aws/cli/cache/` are **not** mounted. Without the flag, `/root/.aws/` is hidden by a tmpfs overlay; with it, the overlay narrows to `/root/.aws/cli/cache/` so the STS credentials the CLI derives in-session don't persist on the shared volume.                                                                                                                                                                                                                                                                                                                                 |
| `--gh`        | Starts a per-session **auth proxy sidecar** that holds the GitHub token — the agent container never sees it. Token discovery is unchanged (`GH_TOKEN` / `GITHUB_TOKEN`, else host `gh auth token`, else a silent skip with no sidecar and legacy no-token behavior). When a token is found, the agent container gets a placeholder `GH_TOKEN=claude-docker-proxy`, GitHub traffic is redirected to the sidecar, and the real `Authorization` header is injected in transit. `/root/.config/gh` stays masked while the sidecar is active. See [GitHub auth proxy](docs/auth.md#github-auth-proxy). |
| `--gh-direct` | Legacy escape hatch: same token discovery as `--gh`, but forwards the real token straight into the agent container as `GH_TOKEN` — no sidecar. For custom-hostname GitHub (Enterprise **Server**, `*.ghe.com`) and hosts that can't run the sidecar. Mutually exclusive with `--gh` (combining both is a startup error) and shown as its own `gh-direct` statusline tag. Unmasks in-container `gh auth login` state, same as pre-proxy `--gh`.                                                                                                                                        |
| `--glab`      | Mount the platform-appropriate `glab-cli` config dir read-only (macOS: `~/Library/Application Support/glab-cli`, Linux: `~/.config/glab-cli`) and forward `GITLAB_TOKEN`. Unmasks in-container `glab auth login` state — without the flag, `/root/.config/glab-cli/` is hidden by a tmpfs overlay.                                                                                                                                                                                                                                                                                    |
| `--tfe`       | Mount `~/.terraform.d/credentials.tfrc.json` read-only when present and forward `TF_TOKEN_app_terraform_io`. Targets `app.terraform.io` (HCP Terraform) only — self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are not forwarded. Unmasks in-container `terraform login` state — without the flag, `/root/.terraform.d/` is hidden by a tmpfs overlay. See [Terraform Cloud workflow](docs/auth.md#terraform-cloud-workflow).                                                                                                                                    |
| `--registry`  | Surface host-native private package-registry config so in-container `uv` / `pnpm` / pip installs resolve against your private feed (CodeArtifact, Artifactory, Nexus, …) instead of public npm/PyPI. Read-only mounts of `~/.npmrc` / `uv.toml` / `pip.conf` plus `UV_INDEX_*` / `npm_config_registry` / `PIP_*` env when set. `~/.netrc` is intentionally **not** mounted (too broad). Runtime-only; the build is unaffected. **Whole-file mounts** — see [Private package registries](docs/auth.md#private-package-registries) for the full channel list and the scoping caution.               |

Combine as needed: `claude-docker --aws --gh ~/repo`. `--gh` and `--gh-direct` cannot be combined with each other.

### Session flags

| Flag          | Effect                                                                                                                      |
| ------------- | --------------------------------------------------------------------------------------------------------------------------- |
| `--ephemeral` | Skip the persistent named volumes. No in-container auth state, shell history, or conversation history persists across runs. |
| `--ro`        | Mount every workspace read-only. Prevents the agent from modifying your code.                                               |

`--ro` does **not** block credential flags or restrict network egress — for an isolated review session, combine `--ephemeral` and `--ro` and pass no credential flags:

```bash
claude-docker --ephemeral --ro ~/untrusted-repo
```

For `--iterm` / `--tmux` (teammate split panes), see [Split-pane agent teams](docs/workflows.md#split-pane-agent-teams). In-container YOLO narrows the blast radius compared to running on the host, but see [Threat model](docs/security.md#threat-model) for what it does and doesn't protect.

### Resuming sessions across workspaces

Conversation history persists in the shared `claude-code-home` volume (skipped under `--ephemeral`), so `claude --resume` followed by `Ctrl+A` lists sessions from every workspace you've ever used — not just the one you're currently in.

## Documentation

- [Auth model](docs/auth.md) — AWS SSO, GitHub auth proxy, Terraform Cloud, private registries
- [Security](docs/security.md) — threat model, image vulnerability scanning
- [Maintenance](docs/maintenance.md) — updating pinned tool versions, CI smoke tests
- [Workflows](docs/workflows.md) — host config parity, worktrees, split panes, extending the image

## Related work

claude-docker is the wrong tool if you have no docker or podman (see [Container runtime](#container-runtime)), run an agent other than Claude Code (the image and [Host config parity](docs/workflows.md#host-config-parity) are Claude Code-specific), or want to work on host files with no mount boundary or container start cost. For those cases, [nono](https://github.com/nolabs-ai/nono) sandboxes an agent at the kernel level (Landlock on Linux, Seatbelt on macOS) with no daemon or container, and works with any agent. Its [security policy](https://github.com/nolabs-ai/nono/blob/main/SECURITY.md) describes it as early development with security guarantees "not yet stable" and production use "not recommended".

The two are complementary, not competing: nono's [container docs](https://nono.sh/docs/cli/internals/containers.md) recommend running it inside a container, which gives namespace isolation and resource limits while nono adds path-level filesystem control and credential blocking. To do that here, install nono in a child image (see [Extending the image](docs/workflows.md#extending-the-image)). nono is not built into the base image; see [#75](https://github.com/schubergphilis/claude-docker/issues/75) and [#12](https://github.com/schubergphilis/claude-docker/issues/12).

## Specs

Behavioural requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).

## License

Licensed under the Apache License, Version 2.0 — see [`LICENSE`](LICENSE) and [`NOTICE`](NOTICE).

The software is provided on an **"AS IS" basis, without warranties or conditions of any kind**, express or implied, including any warranty as to its **security, fitness, or suitability** for a particular purpose. The container narrows blast radius but is **not** a full sandbox (see [Threat model](docs/security.md#threat-model)) — you are responsible for assessing whether it meets your own security requirements before use. claude-docker installs and runs third-party software under its own license and is not affiliated with or endorsed by Anthropic.
