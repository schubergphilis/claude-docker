## 1. Image

- [ ] 1.1 Remove the Go install block and the `GO_VERSION` / `GO_SHA256_*` ARGs from the Dockerfile, and the Go note next to the other manual pins
- [ ] 1.2 Remove the Go `ENV` (`GOBIN`, `GOPATH`, `GOROOT`) and `/usr/local/go/bin` and `/root/go/bin` from PATH, with the comments that explain them
- [ ] 1.3 Reword `.grype.yaml`'s go-module comment so it no longer refers to `/usr/local/go`; keep the rule
- [ ] 1.4 Drop the Go example from the secret-scan comment in `.github/workflows/ci.yml`

## 2. Refresh tooling

- [ ] 2.1 Remove `go_latest_stable` and the Go reminder from `scripts/update_pins.py`
- [ ] 2.2 Update `tests/test_update_pins.py` (manual-pin reminder block, `go_latest_stable` patches)

## 3. Tests

- [ ] 3.1 `tests/smoke/assert-in-container.sh`: drop the Go PATH and `GO*` assertions, assert `go` is absent and `GO*` unset, keep the `/usr/bin` before `/root/.local/bin` check
- [ ] 3.2 Check `tests/bats/` and `scripts/verify-pinned-versions.sh` for Go assumptions

## 4. Docs

- [ ] 4.1 `docs/usage.md`: Go child-image recipe in *Extending the image*, with a pinned sha256-verified tarball
- [ ] 4.2 `docs/vision-and-scope.md`: drop the Go exception wording if any; keep the "Node ships because Claude Code needs it" line
- [ ] 4.3 `docs/security.md`, `SECURITY.md`, `docs/maintenance.md`, `README.md`: stop listing Go as a bundled tool, its code-fetch path and its pin
- [ ] 4.4 Release note for users of `go` in a session

## 5. Verify

- [ ] 5.1 `openspec validate remove-go-toolchain --strict`
- [ ] 5.2 Local checks from CONTRIBUTING (build the image, smoke, unit and BATS tests)
- [ ] 5.3 Archive the change; fill in the PR template's OpenSpec section; `Closes #219`
