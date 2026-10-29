## 1. Spec

- [x] 1.1 ADDED `homebrew-distribution` capability
- [x] 1.2 MODIFIED `image-distribution`: *The distribution channel is documented*
- [x] 1.3 `openspec validate add-homebrew-install --strict` passes
- [ ] 1.4 Proposal and design reviewed before implementation starts

## 2. Tap access

- [ ] 2.1 Agree with the `schubergphilis/homebrew-tap` maintainers who merges formula pull requests
- [ ] 2.2 Machine account and `HOMEBREW_TAP_TOKEN` repository secret (`public_repo`), or a GitHub App on the tap (design D5)

## 3. Formula (pull request on `schubergphilis/homebrew-tap`, from a fork)

- [ ] 3.1 `Formula/claude-docker.rb` at the current stable release: source-archive `url` and `sha256`, `run.sh` in `libexec`, the `bin/claude-docker` launcher (design D2), `caveats` naming the runtimes, `test do` on `--help`
- [ ] 3.2 Locally: `brew install --build-from-source`, `brew test`, `brew audit --strict --new`, `brew style`
- [ ] 3.3 End-to-end on a Mac with no checkout: Colima and Docker Desktop, default image and `CLAUDE_DOCKER_IMAGE` override
- [ ] 3.4 Open the pull request from a fork; merged by a tap maintainer

## 4. Release workflow

- [ ] 4.1 `.github/workflows/homebrew.yml`: `workflow_run` on the Docker workflow, success only, stable `vX.Y.Z` tags only; `workflow_dispatch` with a tag input
- [ ] 4.2 Bump with `mislav/bump-homebrew-formula-action`, pinned by SHA with a matching version comment, using `HOMEBREW_TAP_TOKEN`; minimal `permissions:`
- [ ] 4.3 `tests/test_homebrew_workflow.py`: the tag filter rejects `-rc.N`, the job requires a successful Docker run, every action is SHA-pinned

## 5. Docs

- [ ] 5.1 `README.md` Quickstart: Homebrew first, building from a clone still supported
- [ ] 5.2 `docs/installation.md`: Homebrew install, upgrade and uninstall; default image and override; arm64 scan gap; release candidates never offered; what to do when a release opened no tap pull request
- [ ] 5.3 `docs/maintenance.md`: the tap, the token or App, who owns and rotates it

## 6. Archive

- [ ] 6.1 `/opsx:archive` (syncs `openspec/specs/`)
- [ ] 6.2 First release after merge: tag → image → tap pull request → `brew upgrade` picks it up
