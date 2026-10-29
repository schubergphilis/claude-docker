## 1. Spec

- [x] 1.1 ADDED `homebrew-distribution` capability
- [x] 1.2 MODIFIED `image-distribution`: *The distribution channel is documented*
- [x] 1.3 `openspec validate add-homebrew-install --strict` passes

## 2. Tap access

- [ ] 2.1 A tap maintainer merges the formula pull request, and release pull requests from then on
- [ ] 2.2 Machine account and `HOMEBREW_TAP_TOKEN` repository secret (`public_repo`), or a GitHub App on the tap (design D5)

## 3. Formula (pull request on `schubergphilis/homebrew-tap`, from a fork)

- [x] 3.1 `Formula/claude-docker.rb` at the current stable release: source-archive `url` and `sha256`, `run.sh` in `libexec`, the `bin/claude-docker` launcher (design D2), `caveats` naming the runtimes, `livecheck` on GitHub's latest release, `test do` on `--help`
- [x] 3.2 Locally: install from a local tap, `brew test`, `brew audit --strict --new --online`, `brew style`
- [x] 3.3 Launcher image selection with a stub `docker`: default is `ghcr.io/schubergphilis/claude-docker:v1.1.0`, `CLAUDE_DOCKER_IMAGE` wins, `run.sh` from a checkout still runs `claude-code:local`; through macOS `/bin/bash` 3.2
- [ ] 3.4 End-to-end on a Mac with no checkout: a real session on Colima and on Docker Desktop
- [ ] 3.5 Open the pull request from a fork; merged by a tap maintainer

## 4. Release workflow

- [x] 4.1 `.github/workflows/homebrew.yml`: reusable, called by a `homebrew` job in `docker.yml` that needs the publishing job, tag refs only; stable `vX.Y.Z` only; image checked before bumping; `workflow_dispatch` with a tag input (design D4)
- [x] 4.2 Bump with `mislav/bump-homebrew-formula-action`, pinned by SHA with a matching version comment, using `HOMEBREW_TAP_TOKEN`; `create-pullrequest: true`; `packages: write` moved to the publishing job
- [x] 4.3 `tests/test_homebrew_workflow.py`: the tag filter rejects `-rc.N`, the image check precedes the bump, the job needs the publishing job, only the publishing job can write packages
- [x] 4.4 zizmor (offline, `min-severity: low` as CI) and yamllint clean over the changed workflows; actionlint 1.7.12, not run in CI, does not know the `$/` self-repository syntax zizmor requires yet

## 5. Docs

- [x] 5.1 `README.md` Quickstart: Homebrew first, building from a clone still supported
- [x] 5.2 `docs/installation.md`: Homebrew install, upgrade and uninstall; default image and override; arm64 scan gap; release candidates never offered
- [x] 5.3 `docs/maintenance.md`: the tap, the token, what to do when a release opened no tap pull request, testing a formula change

## 6. Archive

- [ ] 6.1 `/opsx:archive` (syncs `openspec/specs/`)
- [ ] 6.2 First release after merge: tag → image → tap pull request → `brew upgrade` picks it up
