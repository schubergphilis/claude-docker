## Why

The only supported way to get this image is to build it. [`README.md`](../../../README.md)'s
Install section opens with `docker build -t claude-code:local .`, and every wrapper default
points at that locally built tag. That is fine for a maintainer and expensive for everyone
else: a first build pulls the Ubuntu base, an AWS CLI zip, a ~64 MB Go tarball, the
NodeSource and Cloudsmith apt repos and three npm globals, and it has to be repeated on every
machine and after every pin bump.

It also means there is no artifact to point at. `pins/*.env` makes a build reproducible from a
committed lockfile, but nothing publishes the result, so "the image built from `v0.1.0`" is
not a thing anyone can fetch, diff or scan out of band. [`image-scan.yml`](../../../.github/workflows/image-scan.yml)
already works around this by rebuilding `main`'s image weekly rather than pulling it, with a
comment saying so.

This change adds a published artifact without changing how the image is built. Narrow
successor to [#17](https://github.com/schubergphilis/claude-docker/pull/17), which set out to
do the same thing but grew a multi-stage Dockerfile split, a baked-in user at UID/GID 999 and
an entrypoint privilege-drop rework alongside it.

## What Changes

- Add **`.github/workflows/docker.yml`**, which runs the house
  `schubergphilis/mcvs-docker-action` to build, lint, scan and — on a `v*` tag push only —
  publish to `ghcr.io/schubergphilis/claude-docker`. The action's push step is itself gated on
  `github.event_name == 'push' && contains(github.ref, 'refs/tags/')`, so the `tags: [v*]`
  filter is what makes publishing happen at all.
- **Publish a multi-architecture manifest list covering `linux/amd64` and `linux/arm64`.**
  The Dockerfile is already fully multi-arch — `glab`, AWS CLI, `uv` and Go each branch on
  `dpkg --print-architecture`/`uname -m` against per-arch pins — so amd64-only publishing
  would have made the image run emulated for every arm64 Docker Desktop and Colima user, which
  is a large share of this tool's audience. `platforms` is passed explicitly rather than left
  to the action's default, because it names what gets published.
- **Accept that only one architecture is scanned.** The action loads a single image into the
  docker store for dockle, dive and grype and prefers `linux/amd64`; arm64 is built and
  published without passing those scanners. Scanning both requires running the action in a
  matrix with one platform per job, which cannot also publish one manifest list from one job.
  Recorded as a limitation in the README and as a follow-up, not silently absorbed.
- **No `pull_request` trigger.** [`ci.yml`](../../../.github/workflows/ci.yml)'s `Docker build
  (validate, no push)` already builds on every PR with a `type=gha` layer cache that this
  action does not use, and now builds one architecture where this builds two, the second under
  QEMU. On this PR's own checks the cached build took 1m10s against 3m0s/4m6s uncached. The
  scan runs on `main` after merge and on demand via `workflow_dispatch`.
- Add **`.grype.yaml`** and **`.dockleignore`** as the scanner-suppression records. The action
  hardcodes `severity-cutoff: high`, `fail-build: true` and `only-fixed: false` with no input
  to relax any of them, and the scan runs *before* the push — so without these the job fails
  and nothing can ever publish. Both are scoped by package type or location rather than by
  CVE ID, so they do not go stale the way a pinned identifier would.
- **Keep the job advisory.** `main`'s ruleset requires `Validate` and `Docker build (validate,
  no push)`; this context is deliberately not added. With `only-fixed: false` at a `high`
  cutoff, a CVE disclosed against ubuntu/node/Go turns it red on a PR that never touched the
  image, and the author cannot fix it. The flip side is stated in the README: because the scan
  gates the push, a red run on a `v*` tag means the release does not publish.
- Document the channel in [`README.md`](../../../README.md): the pull command, the tag scheme,
  which architectures are published and which are scanned, and that a locally built image
  remains fully supported.

Not in scope:

- **Changing how the image is built.** `Dockerfile`, `entrypoint.sh`, `run.sh` and `ci.yml`
  are untouched. `run.sh` keeps defaulting to `claude-code:local`; consuming the published
  image is `CLAUDE_DOCKER_IMAGE`, which already exists for exactly this.
- **Cutting a release.** This change makes publishing possible; no `v*` tag is pushed here, so
  nothing publishes until an operator pushes one. GHCR creates the package private on first
  push and it needs a one-time flip to public.
- **`latest`, or semver tag expansion.** The action forces `flavor: latest=false` and
  `docker/metadata-action`'s `type=ref` default, with no input to change either, so `v0.1.0`
  publishes exactly `:v0.1.0`. Consumers pin the full `v`-prefixed tag.
- **Signing, SBOM publication and provenance attestations.** The action sets
  `provenance: false` to keep `unknown/unknown` entries out of the registry listing. Cosign
  signing and SBOM attachment are a separate decision.
- **Retiring the Trivy scans.** `ci.yml` and `image-scan.yml` keep their Trivy gate. This
  change adds grype through the house action; the two are not merged here.

## Capabilities

### New Capabilities

- `image-distribution`: the image is published to a container registry on a version tag, as a
  multi-architecture manifest list, behind the same lint-and-scan gate the build already
  passes — with the published reference, its tag scheme and its scan coverage documented.

### Modified Capabilities

None. `image-vulnerability-scan` keeps every requirement it has: its Trivy gate on the PR
build and its weekly re-scan of `main` are unchanged, and this change's grype scan is an
additional, differently-scoped signal on a different trigger rather than a replacement.
`container-runtime`, `host-config-parity` and the credential capabilities describe how the
wrapper runs an image, not where that image comes from, and `CLAUDE_DOCKER_IMAGE` already
exists as the supported override.

## Impact

- `.github/workflows/docker.yml` — new; `push` on `main` and `v*` tags plus
  `workflow_dispatch`, `permissions: contents: read` + `packages: write`.
- `.grype.yaml` — new; three ignore rules, each scoped by package type or location.
- `.dockleignore` — new; the two checkpoints that can fail at the action's `exit-level: warn`.
- `README.md` — new section documenting GHCR as an install path.
- New third-party CI dependency: `schubergphilis/mcvs-docker-action`, pinned by commit SHA
  with a trailing version comment like every other action here. Dependabot's `github_actions`
  ecosystem already covers it.
- It transitively adds hadolint, dockle, dive, grype and `docker/metadata-action` to the
  pipeline. Their thresholds are fixed inside the action and cannot be relaxed from here; the
  two suppression files are the only lever.
- The pin is a **pre-release** (`v0.11.8-rc.1`). It is the first tag carrying the `platforms`
  input that makes multi-arch publishing possible; `design.md` records why an rc was accepted
  over waiting for GA or over the alternatives.
- Build time on `main` grows: two architectures, the second emulated under QEMU. Nothing on
  the PR path changes, because there is no PR trigger.
