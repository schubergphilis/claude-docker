## Why

`docs/vision-and-scope.md` says the image carries the tools the agent needs, and
that a project's language runtimes are fetched per project or go in a child
image. Go is the one exception: #27 added it, nothing else in the image depends
on it, and every user pulls its ~64 MB tarball. It also costs upkeep out of
proportion to its use: a manual pin that `update_pins.py` can only remind about,
and stdlib CVEs that fail the grype gate on their own schedule (8 High ones
forced the 1.26.11 bump on 2026-11-21).

#219 asked whether Go fits the page. The maintainers chose to remove it and
give users a child-image recipe instead.

## What Changes

- **BREAKING** The base image no longer ships Go: no `/usr/local/go`, no `go` on
  PATH, no `GOROOT` / `GOPATH` / `GOBIN`, no `/root/go/bin` or
  `/usr/local/go/bin` in PATH. Users of `go` in a session need a child image.
- `Dockerfile`: drop the Go install block, its `GO_VERSION` / `GO_SHA256_*`
  ARGs, the Go `ENV`, and the Go entries in PATH.
- `scripts/update_pins.py`: drop the Go reminder and `go_latest_stable`.
- `.grype.yaml`: the `/usr/bin/**` go-module rule stays (it covers the prebuilt
  gh, glab and task binaries); only its comment about `/usr/local/go` goes.
- Docs: `docs/usage.md` gets a Go child-image recipe in *Extending the image*;
  `docs/vision-and-scope.md`, `docs/security.md`, `docs/maintenance.md`,
  `SECURITY.md` and `README.md` stop listing Go.
- Tests: smoke and unit tests that assert Go's PATH entry, environment and
  reminder.
- Release note for anyone who uses `go` in a session.

## Capabilities

### Removed Capabilities

- `go-toolchain`: every requirement is removed. Its PATH-ordering requirement
  carries on, without Go, in `package-managers`.

### Modified Capabilities

- `package-managers`: ADDED *Go is not preinstalled and a child-image recipe is
  documented*; ADDED *PATH ordering keeps volume-persisted directories
  non-shadowing* (moved from `go-toolchain`, without Go).
- `version-pin-refresh`: MODIFIED *Operator report*, *the task pin is manual and
  surfaced as an operator reminder* and *the task reminder's version resolution
  is best-effort*, so none of them names Go.

## Impact

- `Dockerfile`, `scripts/update_pins.py`, `tests/test_update_pins.py`,
  `tests/smoke/assert-in-container.sh`, `.grype.yaml`, `.github/workflows/ci.yml`
  (comment), `docs/`, `SECURITY.md`, `README.md`.
- Image size drops by the Go tree. The Go-toolchain half of the grype gate goes
  with it; the `/usr/bin/**` go-module rule stays for the prebuilt binaries.
- Existing `claude-code-root` volumes keep any `/root/go` content (module cache,
  `go install` output). It is no longer on PATH, and stays until the user
  deletes it.
