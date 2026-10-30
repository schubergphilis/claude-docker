# Installation

[← Back to the README](../README.md)

The [Quickstart](../README.md#quickstart) installs with Homebrew or builds the image from your checkout. This page covers the Homebrew install, the BuildKit requirement of the build, and the prebuilt image published to GHCR.

## Homebrew

```bash
brew tap schubergphilis/claude-docker https://github.com/schubergphilis/claude-docker
brew install claude-docker
```

This repository is its own tap: the formula is [`Formula/claude-docker.rb`](../Formula/claude-docker.rb). `brew tap` keeps a copy of the repository inside Homebrew to read the formula from; you don't work in it. The formula installs `run.sh` from the latest stable release's source archive, checked against its sha256, behind a `claude-docker` launcher on your `PATH`. There is no build. You still need a container runtime: Docker Desktop, Colima or Podman (see [Container runtime](usage.md#container-runtime)). The formula installs none, since any of them works.

**The launcher runs the published image of its own version.** `claude-docker` 1.2.3 runs `ghcr.io/schubergphilis/claude-docker:v1.2.3`, pulled on first use, so the wrapper and its image always match. Set `CLAUDE_DOCKER_IMAGE` to run another, such as a local build: your value wins over the launcher's. `run.sh` from a checkout is unchanged and still defaults to `claude-code:local`.

**On Apple Silicon you get the `linux/arm64` image, which the publish scans do not cover.** dockle, dive and grype only see `linux/amd64`; see [scan coverage](#prebuilt-image-from-ghcr) below. If that matters to you, build locally and point `CLAUDE_DOCKER_IMAGE` at it.

**Only stable releases reach Homebrew.** Each stable `vX.Y.Z` tag whose image is published opens a pull request here that moves the formula to it. Once it merges, `brew update && brew upgrade claude-docker` picks it up. Release candidates are never offered. The image of the previous version stays published, so a formula that has not moved yet keeps working.

```bash
brew update && brew upgrade claude-docker
brew uninstall claude-docker && brew untap schubergphilis/claude-docker
```

Uninstalling leaves the pulled images and the session volumes in your container runtime; remove them with `docker image rm` and `docker volume rm` if you want them gone.

## BuildKit on Colima

The build needs BuildKit (the Dockerfile uses `COPY --chmod`). Docker Desktop ships it by default. A Homebrew `docker` CLI with Colima does **not**: the buildx plugin is a separate formula, and without it `docker build` silently falls back to the legacy builder and dies at the `COPY --chmod` step with `the --chmod option requires BuildKit`. One-time fix:

```bash
brew install docker-buildx
mkdir -p ~/.docker/cli-plugins
ln -sfn "$(brew --prefix)/opt/docker-buildx/bin/docker-buildx" ~/.docker/cli-plugins/docker-buildx
```

Verify with `docker buildx version`, then rerun the same `docker build` — with the plugin present, plain `docker build` uses BuildKit automatically.

## Prebuilt image from GHCR

Released versions are published to `ghcr.io/schubergphilis/claude-docker`, so you can skip the build:

```bash
docker pull ghcr.io/schubergphilis/claude-docker:v0.1.0
export CLAUDE_DOCKER_IMAGE=ghcr.io/schubergphilis/claude-docker:v0.1.0
```

`CLAUDE_DOCKER_IMAGE` is the existing image override ([Extending the image](usage.md#extending-the-image) uses the same variable); `run.sh` still defaults to `claude-code:local`, and building from your checkout stays fully supported. Pin whichever you use — an image and the `run.sh` beside it are not independently versioned.

**Pin the full `v`-prefixed tag.** A `v0.1.0` tag publishes exactly `:v0.1.0` — there is no `latest`, no `:0.1`, and no semver expansion. The publishing action forces `flavor: latest=false` on `docker/metadata-action`'s default `type=ref` tagging and exposes no input to change either.

**Release candidates are published too, and are not supported.** The `v*` trigger does not distinguish a candidate from a release, so pre-release tags such as `v0.1.0-rc.6` are built, scanned and pushed exactly like a stable one — several are public right now. They exist so a candidate can be pulled and checked against the registry before a release is committed to, and because tagging is `type=ref` with no `latest`, an RC can never move or shadow a stable tag. Use them only if you cut them: if you hit a bug on one, retry against the latest stable tag and report it there — an RC is never fixed in place.

**Architectures.** The manifest list covers `linux/amd64` and `linux/arm64`, so Apple Silicon and arm64 Colima hosts get a native image rather than an emulated one — the same set the Dockerfile already supports, since every third-party download in it branches on the build architecture against per-arch pins.

**Scan coverage is not symmetric, and you should know which half you're getting.** The publish pipeline lints with hadolint and dockle and scans with dive and grype, but only one architecture reaches those tools: the action loads a single image into the local docker store and prefers whichever platform the runner provides natively, which is `linux/amd64`. So **`linux/arm64` is built and published without passing dockle, dive or grype.** Both images come from one Dockerfile and one set of pins, and the findings that drive the suppressions in [`.grype.yaml`](../.grype.yaml) are vendored-code findings that reproduce identically on both — but the gap is real and is recorded here rather than implied away. `ci.yml`'s Trivy gate and the weekly [image scan](security.md#image-vulnerability-scanning) are likewise amd64-only.

Because that scan runs *before* the push, **a `v*` tag whose pipeline run goes red publishes nothing.** If a tag exists here with no package behind it, check the Docker workflow run for that tag before assuming a registry problem. If there is no Docker run for the tag at all, the release workflow created the tag but failed to dispatch the build — re-running the release job does not retry that, so start it yourself with `gh workflow run docker.yml --ref <tag>`. That is safe to run: the pipeline refuses a tag that is already published and fails the run, so it only ever fills in a missing image.
