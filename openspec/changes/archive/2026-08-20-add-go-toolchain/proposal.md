## Why

The image ships CLIs but no Go toolchain, so any Go work inside a session dies
at `go: command not found` — building or testing a Go repo, running
`go run ./...` against a mounted workspace, or installing a Go-based tool with
`go install`. The workarounds are all worse than shipping it: `apt install
golang-go` at runtime needs network plus a package whose version tracks Ubuntu's
archive rather than the project's `go.mod`, and a child image
(`FROM claude-code:local`) is the documented escape hatch for *project-specific*
runtimes — overkill for a toolchain this widely needed.

Go is also a poor fit for the runtime-fetch pattern the image uses for
Terraform and Python. `tfenv` exists because terraform versions are pinned
per-workspace and a bundled binary would drift; `uv` exists because it manages
its own interpreter downloads. Go needs neither: the distribution is a single
self-contained tree, and `go` already resolves a project's required toolchain
itself when `go.mod` asks for a newer one.

## What Changes

- **Install the Go toolchain** from the official `go.dev` tarball into
  `/usr/local/go` (per go.dev/doc/install), arch-aware for `amd64` and `arm64`,
  pinned to `GO_VERSION=1.26.6` with a per-arch sha256 verified before
  extraction — the same pin-and-verify model as `uv`, `glab`, the AWS CLI, and
  `tfenv`. The step is placed before the npm layer so a weekly `claude-code` pin
  bump does not re-download the ~64 MB tarball.
- **Extend PATH** with `/usr/local/go/bin` first and `/root/go/bin` (the GOPATH
  default for the dropped user, inside the persistent `claude-code-root` volume)
  **last**, so `go install` output is runnable by name but cannot shadow a
  system binary on a later run.
- **Keep the pin manual, but visible**: `update_pins.py` gains Go in its
  manual-pin reminder block (pinned vs newest stable on go.dev, best-effort)
  next to `nodejs` and the base-image digest. Go cannot join the automated
  `pins/` fragments because go.dev's release feed carries no publish dates, so
  the 7-day soak window cannot be evaluated from it.
- **Document the new fetch surface**: the README threat model gains
  `proxy.golang.org` module downloads and the fact that default
  `GOTOOLCHAIN=auto` makes the image's Go pin a floor, not a ceiling
  (`GOTOOLCHAIN=local` refuses the auto-download).

Out of scope: no new `run.sh` flag, no credential handling, no Go build cache
volume, no second toolchain or version manager (`gvm`/`asdf`), and no change to
the automated pin machinery under `pins/`.

## Capabilities

### New Capabilities

- `go-toolchain`: the image ships exactly one version-pinned, sha256-verified Go
  toolchain on the default PATH; the pin is manual with an operator reminder;
  PATH ordering keeps volume-persisted GOPATH binaries non-shadowing; and the
  toolchain's runtime code-fetch paths are documented in the threat model.

### Modified Capabilities

- `package-managers`: its Purpose currently asserts that "project-specific
  language runtimes (rust, go, ruby, etc.) are deliberately excluded — they
  belong in child images". Go is now the documented exception and that sentence
  is reworded in place; rust/ruby/etc. remain excluded on the same reasoning.
  This is a Purpose edit, which the delta format does not express (deltas carry
  requirement sections only), so it is applied directly to
  `openspec/specs/package-managers/spec.md` and recorded here.

## Impact

- **Code**: `Dockerfile` — new `ARG GO_VERSION` / `GO_SHA256_AMD64` /
  `GO_SHA256_ARM64` plus the download-verify-extract `RUN`; `PATH` added to the
  existing `ENV` block; the "every other tool is a generated pin" comment now
  names Go as the second manual pin. `update_pins.py` — `go_latest_stable()` and
  a Go line in `print_reminders()`.
- **Docs**: `README.md` — preinstalled-tools line, runtime code-fetch bullet,
  the two sha256-verified download lists, and the manual-pins paragraph.
- **Specs**: new `go-toolchain` delta; Purpose reword in
  `specs/package-managers/spec.md` (see above).
- **No breaking changes**: purely additive. Existing sessions gain `go` on PATH;
  nothing that worked before changes behaviour. Image size grows by the
  extracted Go tree — ~265 MB on disk from a ~64 MB tarball (measured for
  1.26.6/arm64).
- **Dependencies**: a new build-time download host, `go.dev` (redirecting to
  Google's release CDN), hash-pinned per arch. New runtime egress targets when
  Go is actually used: `proxy.golang.org` and `sum.golang.org`.
