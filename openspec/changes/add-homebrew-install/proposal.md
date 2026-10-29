## Why

Installing claude-docker today means cloning the repository, building a
multi-hundred-megabyte image, and symlinking `run.sh` onto the `PATH`. The
image is already published to GHCR on every release, and `run.sh` is a single
self-contained script, so the clone is only there to get one file and to
build an image nobody has to build any more.

A Homebrew formula removes both steps:
`brew install schubergphilis/tap/claude-docker` installs the wrapper, and the
first run pulls the published image that matches it. Upgrades become
`brew upgrade`, and the wrapper and the image it runs move together instead of
being pinned by hand.

## What Changes

- **A `claude-docker` formula in `schubergphilis/homebrew-tap`**, the existing
  Schuberg Philis tap. It installs from the release's GitHub source archive,
  keeps `run.sh` private to the formula, and puts a `claude-docker` launcher on
  the `PATH`. The tap is changed by pull request from a fork; its maintainers
  merge.
- **A Homebrew install defaults to the matching published image.** The
  launcher sets `CLAUDE_DOCKER_IMAGE` to
  `ghcr.io/schubergphilis/claude-docker:v<formula version>` unless the user
  already set it. `run.sh` itself is unchanged: a clone still defaults to
  `claude-code:local`.
- **Releases update the formula.** A new workflow opens the tap pull request
  that moves the formula to a release, but only for a stable `vX.Y.Z` tag and
  only once that tag's image is published. Release candidates never reach the
  tap.
- **Docs.** The README Quickstart offers Homebrew first, building from a clone
  stays a supported path, and `docs/installation.md` covers install, upgrade,
  the default image, overriding it, and the arm64 scan gap a Homebrew user on
  Apple Silicon inherits.

## Non-goals

- homebrew-core. Its notability bar and its rule against formulae that need a
  container runtime rule it out for now; the tap name is the price.
- Windows. The PowerShell launcher and WSL route are unchanged.
- Changing what is published to GHCR or how it is scanned.

## Capabilities

### New Capabilities

- `homebrew-distribution`: where the formula lives, what it installs, the
  launcher's default image and its override, which releases reach the tap and
  when, and the formula's offline test.

### Modified Capabilities

- `image-distribution`: *The distribution channel is documented* — the
  wrapper keeps defaulting to the locally built tag when run from a clone; a
  Homebrew install defaults to the published tag of its own version, and the
  docs present Homebrew as an install path.

## Impact

- New: `.github/workflows/homebrew.yml`, `tests/test_homebrew_workflow.py`.
- Changed: `.github/workflows/docker.yml` (calls the bump after publishing;
  `packages: write` moves to the publishing job), `README.md`,
  `docs/installation.md`, `docs/maintenance.md`.
- Outside this repository: `Formula/claude-docker.rb` in
  `schubergphilis/homebrew-tap`, by pull request from a fork.
- A repository secret holding a token that can fork the tap and open pull
  requests on it (see design D5). Each release's tap pull request still needs
  a tap maintainer to merge it.
