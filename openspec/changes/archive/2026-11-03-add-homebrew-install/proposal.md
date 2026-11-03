## Why

Installing claude-docker today means cloning the repository, building a
multi-hundred-megabyte image, and symlinking `run.sh` onto the `PATH`. The
image is already published to GHCR on every release, and `run.sh` is a single
self-contained script, so the clone is only there to get one file and to
build an image nobody has to build any more.

A Homebrew formula removes both steps:

```bash
brew tap schubergphilis/claude-docker https://github.com/schubergphilis/claude-docker
brew install claude-docker
```

installs the wrapper, and the first run pulls the published image that
matches it. Upgrades become `brew upgrade`, and the wrapper and the image it
runs move together instead of being pinned by hand.

## What Changes

- **This repository becomes its own Homebrew tap.**
  - `Formula/claude-docker.rb` installs from the latest stable release's
    GitHub source archive, keeps `run.sh` private to the formula, and puts a
    `claude-docker` launcher on the `PATH`.
  - The formula is changed only by pull request here, reviewed like any other
    change.
- **A Homebrew install defaults to the matching published image.** The
  launcher sets `CLAUDE_DOCKER_IMAGE` to
  `ghcr.io/schubergphilis/claude-docker:v<formula version>` unless the user
  already set it. `run.sh` itself is unchanged: a clone still defaults to
  `claude-code:local`.
- **Releases update the formula.** After a stable `vX.Y.Z` tag's image is
  published, `docker.yml` calls a new workflow that opens a `chore` pull
  request here, moving the formula to that tag. Merging it cuts no release.
  Release candidates and tags with no published image never reach the formula.
- **Docs.**
  - The README Quickstart offers Homebrew first; building from a clone stays a
    supported path.
  - `docs/installation.md` covers install, upgrade, the default image,
    overriding it, and the arm64 scan gap a Homebrew user on Apple Silicon
    inherits.
  - `docs/maintenance.md` covers the bump and a missed one.

## Non-goals

- homebrew-core. Its notability bar and its rule against formulae that need a
  container runtime rule it out for now.
- The shared `schubergphilis/homebrew-tap`. It has had no maintainer since
  2024; a tap in this repository is maintained with the code it installs.
- Windows. The PowerShell launcher and WSL route are unchanged.
- Changing what is published to GHCR or how it is scanned.

## Capabilities

### New Capabilities

- `homebrew-distribution`: the tap and formula, what it installs, the
  launcher's default image and its override, which releases reach the formula
  and when, and the formula's offline test.

### Modified Capabilities

- `image-distribution`: *The distribution channel is documented* — the
  wrapper keeps defaulting to the locally built tag when run from a clone; a
  Homebrew install defaults to the published tag of its own version, and the
  docs present Homebrew as an install path.

## Impact

- New: `Formula/claude-docker.rb`, `.github/workflows/homebrew.yml`,
  `tests/test_homebrew_workflow.py`.
- Changed:
  - `.github/workflows/docker.yml`: calls the bump after publishing;
    `packages: write` moves to the publishing job.
  - `README.md`, `docs/installation.md`, `docs/maintenance.md`.
- No secrets: the bump uses `GITHUB_TOKEN`. Its pull request waits for a
  maintainer to approve its checks, as the pins refresh does, and until it
  merges `brew upgrade` stays on the previous release.
