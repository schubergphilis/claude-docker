## 1. Image

- [x] 1.1 Remove the Go install block and the `GO_VERSION` / `GO_SHA256_*` ARGs from the Dockerfile, and the Go note next to the other manual pins
- [x] 1.2 Remove the Go `ENV` (`GOBIN`, `GOPATH`, `GOROOT`) and `/usr/local/go/bin` and `/root/go/bin` from PATH, with the comments that explain them
- [x] 1.3 Reword `.grype.yaml`'s go-module comment so it no longer refers to `/usr/local/go`; keep the rule
- [x] 1.4 Drop the Go example from the secret-scan comment in `.github/workflows/ci.yml`

## 2. Refresh tooling

- [x] 2.1 Remove `go_latest_stable` and the Go reminder from `scripts/update_pins.py`
- [x] 2.2 Update `tests/test_update_pins.py` (manual-pin reminder block, `go_latest_stable` patches)

## 3. Tests

- [x] 3.1 `tests/smoke/assert-in-container.sh`: drop the Go PATH and `GO*` assertions, assert `go` is absent and `GO*` unset, keep the `/usr/bin` before `/root/.local/bin` check
- [x] 3.2 Check `tests/bats/` and `scripts/verify-pinned-versions.sh` for Go assumptions

## 4. Docs

- [x] 4.1 `docs/usage.md`: Go child-image recipe in *Extending the image*, with a pinned sha256-verified tarball
- [x] 4.2 `docs/vision-and-scope.md`: drop the Go exception wording if any; keep the "Node ships because Claude Code needs it" line
- [x] 4.3 `docs/security.md`, `SECURITY.md`, `docs/maintenance.md`, `README.md`: stop listing Go as a bundled tool, its code-fetch path and its pin
- [ ] 4.4 Release note (goes in the PR description / release draft) for users of `go` in a session

## 5. Review follow-ups

- [x] 5.0a Go child-image recipe: toolchain directory first in PATH, same pruning as the old base block, `GOTOOLCHAIN` link
- [x] 5.0b Stale Go mentions: `docs/auth.md`, `docs/security.md`, `pins-updater.yml`, `docker.yml` dockle keys, `.grype.yaml` comment (covers `git-lfs` too)
- [x] 5.0c Smoke: `check_no_go` with separate assertions and a real unset check; unit test that the Go reminder is gone
- [x] 5.0d Spec deltas: MODIFIED *Every automated pin is verified at runtime* and the `package-managers` code-fetch requirement

## 6. Verify

- [x] 6.1 `openspec validate remove-go-toolchain --strict`
- [ ] 6.2 Local checks from CONTRIBUTING: unit tests pass (207); shellcheck, hadolint, bats and the image build + smoke still to run where docker is available
- [x] 6.3 Archive the change; fill in the PR template's OpenSpec section; `Closes #219`
