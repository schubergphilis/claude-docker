## Context

`run.sh` is one self-contained script: it reads no file from the checkout,
generates its sidecar configs and the egress-proxy Dockerfile inline, and is
written for macOS's system bash 3.2 (`/bin/bash run.sh --help` runs there). Its
image defaults to `claude-code:local`, overridable with `CLAUDE_DOCKER_IMAGE`.

Every stable release tag is published to `ghcr.io/schubergphilis/claude-docker`
for `linux/amd64` and `linux/arm64`, and the package pulls anonymously. A tag
whose `docker.yml` run fails publishes nothing. `release.yml` creates the tag
and dispatches `docker.yml`; release candidates are tagged and published the
same way, by hand.

`schubergphilis/homebrew-tap` exists, is public, and holds one formula
(`grawsp`). It has no CI.

## Goals / Non-Goals

**Goals:** `brew install schubergphilis/tap/claude-docker` gives a working
`claude-docker` with no clone and no build; a Homebrew install runs the image
published for its own version; the formula follows stable releases without a
hand edit; nothing changes for a clone.

**Non-Goals:** homebrew-core; a Windows package; a bottle (there is nothing to
compile); attaching extra release assets.

## Decisions

### D1: Install from the release's source archive

The formula's `url` is
`https://github.com/schubergphilis/claude-docker/archive/refs/tags/vX.Y.Z.tar.gz`,
which GitHub serves for every tag. It is about 1.7 MB, of which the formula
keeps `run.sh`.

Alternative: upload `run.sh` as a release asset and point the formula at it.
Smaller download, but one more step in the release job that can fail between
the tag and the image, and a second artifact to keep in step with the tag.
Revisit if the archive grows.

### D2: A launcher sets the default image; `run.sh` is untouched

```bash
#!/bin/bash
export CLAUDE_DOCKER_IMAGE="${CLAUDE_DOCKER_IMAGE:-ghcr.io/schubergphilis/claude-docker:v<version>}"
exec "<libexec>/run.sh" "$@"
```

`run.sh` goes to the formula's `libexec`; the launcher is `bin/claude-docker`.

- The wrapper and image share a version, which `docs/installation.md` already
  asks users to pin together.
- A user's `CLAUDE_DOCKER_IMAGE` wins, so a local build or another tag still
  works with a Homebrew install.
- A clone keeps defaulting to `claude-code:local`, as `image-distribution`
  requires.

Alternatives rejected:

- `inreplace` on `run.sh`'s `IMAGE=` line at install time: breaks silently
  when that line is reworded.
- Homebrew's `write_env_script`: sets the variable unconditionally, so the
  user's override would be lost.
- Changing `run.sh`'s default to GHCR for everyone: drops the local-build
  default the spec keeps, and `run.sh` does not know its own version.

### D3: No hard dependency on a container runtime

`run.sh` supports Docker Desktop, Colima's `docker` and Podman, and picks the
runtime itself. `depends_on "docker"` would install a CLI the Docker Desktop
and Podman users don't use. The formula states the requirement in `caveats`.
No `depends_on "bash"` either: `run.sh` targets bash 3.2.

### D4: The tap is bumped after the image is published, for stable tags only

`.github/workflows/homebrew.yml` is a reusable workflow. `docker.yml` calls it
as a `homebrew` job that `needs` the publishing job, on tag refs only. A tag
whose publish failed has no image, and the job is then skipped, so the formula
never points at one that does not exist. `homebrew.yml` goes on only for a tag
matching `^v[0-9]+\.[0-9]+\.[0-9]+$`: `-rc.N` tags are published to GHCR on
purpose but are not supported, so they never reach Homebrew.

It is also `workflow_dispatch`able with a tag input, for when a bump is missed.
Re-running `docker.yml` cannot do that, since it refuses a tag that is already
published. A dispatch is held to the same tag rule and also checks the tag's
image is published before bumping.

The publishing job keeps `packages: write`, now at job level, and the Homebrew
job gets `contents: read` only.

Alternatives rejected:

- A step in `release.yml` after the dispatch: the dispatch returns before the
  image is built or scanned.
- `workflow_run` on the Docker workflow: same ordering, but it is a trigger
  that runs with secrets on another workflow's behalf, which zizmor (run by
  CI at `min-severity: low`) reports as dangerous.

### D5: Pull requests from a fork, with a token that can fork

The tap is changed only by pull request, from a fork: no one on this project
needs write access to it, and its maintainers review every formula change. The
first formula is opened that way by hand.

For releases the workflow uses `mislav/bump-homebrew-formula-action`, pinned
by SHA. When its token cannot push to the tap it forks the tap into the
token's account and opens the pull request from there. `GITHUB_TOKEN` can
do neither in another repository, so the workflow reads a repository secret,
`HOMEBREW_TAP_TOKEN`: a token for a machine account (not a person's) with
`public_repo` scope, so it survives people leaving.

If the tap maintainers would rather grant push access, a GitHub App installed
on the tap replaces the secret and the fork; the workflow change is the token
step only.

## Risks / Trade-offs

- **Each release waits on a tap merge.** Until a maintainer merges the tap
  pull request, `brew upgrade` stays on the previous version. Acceptable: the
  previous version and its image keep working, and published tags are
  immutable.
- **Apple Silicon gets the arm64 image, which the publish scans skip.** This
  is the existing gap, but Homebrew makes it the default for most Mac users.
  The Homebrew docs repeat it rather than link to it.
- **The archive checksum could change.** GitHub has said source-archive
  checksums are stable; if one changes, `brew install` fails closed on the
  mismatch, and the fix is a formula update.
- **A token with fork-and-PR rights on public repositories.** Scoped to
  `public_repo` on an account that owns nothing else; used only in a workflow
  with no checkout of untrusted code.

## Open Questions

- Who on the tap side merges release pull requests, and is a machine account
  available for `HOMEBREW_TAP_TOKEN`, or should we ask for a GitHub App now?
