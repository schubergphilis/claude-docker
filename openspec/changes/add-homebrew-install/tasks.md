## 1. Spec

- [x] 1.1 ADDED `homebrew-distribution` capability
- [x] 1.2 MODIFIED `image-distribution`: *The distribution channel is documented*
- [x] 1.3 `openspec validate add-homebrew-install --strict` passes

## 2. Formula (this repository is the tap, design D1)

- [x] 2.1 `Formula/claude-docker.rb` at the current stable release: source-archive `url` and `sha256`, `run.sh` in `libexec`, the `bin/claude-docker` launcher (design D3), `caveats` naming the runtimes, `livecheck` on GitHub's latest release, `test do` on `--help`
- [x] 2.2 Tapped from this repository by path: install, `brew test`, `brew audit --strict --online`, `brew style`
- [x] 2.3 Launcher image selection with a stub `docker`: default is `ghcr.io/schubergphilis/claude-docker:v1.1.0`, `CLAUDE_DOCKER_IMAGE` wins, `run.sh` from a checkout still runs `claude-code:local`; through macOS `/bin/bash` 3.2
- [ ] 2.4 End-to-end on a Mac after merge: tap by URL, a real session on Colima and on Docker Desktop

## 3. Release workflow

- [x] 3.1 `.github/workflows/homebrew.yml`: reusable, called by a `homebrew` job in `docker.yml` that needs the publishing job, tag refs only; stable `vX.Y.Z` only; image checked before bumping; never backwards; `workflow_dispatch` with a tag input (design D5)
- [x] 3.2 Bump on a branch with a `chore(homebrew)` pull request opened with `GITHUB_TOKEN`; `packages: write` moved to the publishing job
- [x] 3.3 The bump script, run in Ubuntu 24.04: an older tag and the current tag leave the formula alone; v1.0.0 → v1.1.0 writes v1.1.0's url and sha256
- [x] 3.4 `tests/test_homebrew_workflow.py`: the tag filter rejects `-rc.N`, the image check precedes the bump, the bump is a `chore` pull request and never a push to `main`, the formula names a stable release of this repository and the launcher default, only the publishing job can write packages
- [x] 3.5 zizmor (offline, `min-severity: low` as CI) and yamllint clean over the changed workflows; actionlint clean on `homebrew.yml` (it does not know the `$/` self-repository syntax in `docker.yml` yet; not run in CI)

## 4. Docs

- [x] 4.1 `README.md` Quickstart: Homebrew first, building from a clone still supported
- [x] 4.2 `docs/installation.md`: tap, install, upgrade and uninstall; default image and override; arm64 scan gap; release candidates never offered
- [x] 4.3 `docs/maintenance.md`: how the bump works, what to do when a release opened no pull request, testing a formula change

## 5. Archive

- [ ] 5.1 `/opsx:archive` (syncs `openspec/specs/`)
- [ ] 5.2 First release after merge: tag → image → bump pull request → `brew upgrade` picks it up
