# Installation

[← Back to the README](../README.md)

The [Quickstart](../README.md#quickstart) builds the image from your checkout. This page covers the BuildKit requirement of that build and the prebuilt image published to GHCR.

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
