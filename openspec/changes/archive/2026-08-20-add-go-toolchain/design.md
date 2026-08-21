## Context

The image installs third-party binaries in two shapes. Automated pins live in
`pins/<tool>.env` — `update_pins.py` selects the newest stable version that has
already cleared a 7-day soak window, downloads both arch artifacts, hashes them,
and rewrites the fragment; the Dockerfile `COPY`s and sources it. Manual pins
live in the Dockerfile itself: `ARG NODE_VERSION` (NodeSource's apt repo has no
cleanly machine-readable publish dates) and the `FROM ubuntu@sha256:…` digest
(moving the base OS is a separately-reviewed decision). `update_pins.py` reports
both as reminders and never rewrites them.

A Go toolchain has to pick one of those shapes. It also has to sit somewhere in
the layer order that does not make cheap pin bumps expensive, and it introduces
a PATH question the other tools do not: `go install` writes into `$HOME/go/bin`,
and `$HOME` is `/root` — inside the persistent `claude-code-root` volume that
survives `docker run --rm`.

## Goals / Non-Goals

**Goals:**

- `go build` / `go test` / `go run` / `go install` work out of the box in a
  session, on both `amd64` and `arm64`.
- The tarball is version-pinned and sha256-verified before extraction, matching
  the existing `uv`/`glab`/AWS CLI/`tfenv` trust model.
- The pin stays visible: an operator running the refresh script learns that a
  newer Go exists even though the script will not touch it.
- No new way for a compromised session to gain persistence on PATH.

**Non-Goals:**

- No Go version manager (`gvm`, `asdf`) and no multiple toolchains in the image
  — `GOTOOLCHAIN=auto` already covers projects needing a newer release.
- No attempt to soak-gate Go from a second, weaker date source.
- No Go build-cache volume; `GOCACHE` lands under `/root/.cache/go-build`, which
  the existing `claude-code-root` volume already persists.
- No `run.sh` flag, credential mount, or egress control for `proxy.golang.org`.

## Decisions

**Decision: install the official go.dev tarball into `/usr/local/go`, not
`apt install golang-go`.**

- *Why not apt?* Ubuntu's `golang-go` tracks the archive's release, not upstream
  stable, and splits the distribution across `/usr/lib/go-<v>` with wrapper
  binaries — a layout that diverges from what `go env GOROOT`-sensitive tooling
  and upstream docs assume. It would also be unpinnable in practice (DL3008 is
  waived precisely because archive versions move under you).
- *Why not `uvx`-style runtime fetch?* There is no per-project Go *distribution*
  to choose the way `.terraform-version` selects a terraform binary; `go.mod`
  selects a *toolchain*, which the shipped `go` resolves itself.

**Decision: manual pin (`ARG GO_VERSION` + per-arch sha256), not a `pins/`
fragment.**
`https://go.dev/dl/?mode=json` lists versions and per-file sha256 but no publish
dates, so the soak window — the thing that makes the automated pins safe to
consume the moment they are generated — cannot be evaluated from it. The
alternatives were both worse than staying manual:

- *Use the `golang/go` git tag's committer date as a soak proxy* (the aws-cli
  pattern). Go publishes no GitHub releases and its tag list is dominated by
  ancient `weekly.*` tags, so this needs tag-by-tag commit lookups against a
  second host, and the committer date is a weaker signal than a publish date —
  the same limitation already flagged for aws-cli, adopted here for no gain,
  since a Go bump also needs a human to read the release notes.
- *Trust the feed's advertised sha256 and skip the soak.* That would make Go the
  only tool whose committed hash was never independently derived from the bytes.

The pin is instead surfaced: `print_reminders()` reads `ARG GO_VERSION` out of
the Dockerfile and compares it to the newest stable on go.dev, best-effort
(empty on any failure, like `ubuntu_current_digest()`).

**Decision: hashes are confirmed by hashing the downloaded bytes, not copied
from the feed.**
The initial pin's two hashes were produced by downloading both tarballs and
running `sha256sum`, then checked against the feed's advertised digests. The
Dockerfile comment tells the next bumper to do the same. This keeps the
"committed hash provably covers the artifact the build fetches" property that
`_arch_url_sha_lines()` gives the automated pins.

**Decision: place the Go layer before the npm-backed CLIs.**
The tarball is ~64 MB and Go patches land every few weeks; `claude-code` moves
weekly. Putting Go *after* the npm layer would re-download it on every
`claude-code` bump. Putting it before means a Go bump invalidates the npm layer
instead — the cheaper direction, and the same reasoning the `tfenv` block
already documents in reverse.

**Decision: `PATH=/usr/local/go/bin:${PATH}:/root/go/bin` — GOPATH bin last.**
`go install` output has to be runnable by name or the toolchain is half-useful.
But `/root/go/bin` is agent-writable *and* volume-persisted, so putting it early
would let one session drop a `git` (or `gh`, or `aws`) there and have the next
session execute it. Appending it after every system path removes the shadowing
primitive while keeping the convenience; `/usr/local/go/bin` goes first so the
image's pinned toolchain always wins over anything in the volume.

- *Rejected: omit `/root/go/bin` entirely.* Safest, but `go install`ed tools
  then need absolute paths, which is a papercut on exactly the workflow this
  change exists to enable.
- *Rejected: symlink `go`/`gofmt` into `/usr/local/bin`* (the `tfenv`/`uv`
  pattern). Works — the official tarball bakes `GOROOT=/usr/local/go` so
  invocation path does not matter — but it diverges from go.dev's documented
  install and leaves `go install` output off PATH anyway.

**Decision: leave `GOTOOLCHAIN` at its default `auto`.**
Setting `GOTOOLCHAIN=local` would make the image's pin authoritative, the way
`DISABLE_AUTOUPDATER=1` does for `claude-code`. Rejected: a `go.mod` requiring a
newer Go is routine, and failing every such build would push users straight back
to unpinned ad-hoc installs. The auto-downloaded toolchain is checksum-verified
through the module/sumdb machinery, which is a stronger guarantee than the
`tfenv install` fetch the image already accepts. The consequence — the pin is a
floor, not a ceiling — is documented in the threat model rather than engineered
away, and `GOTOOLCHAIN=local` is named as the opt-out for anyone who wants it.

**Decision: new `go-toolchain` capability rather than extending
`package-managers`.**
`package-managers` is scoped to `uv`/`pnpm` as general-purpose user-tier package
managers; a language toolchain is a different concern with its own pin, PATH,
and fetch-surface requirements. Its Purpose does, however, currently claim that
`go` is deliberately excluded, so that sentence is reworded in place — the delta
format carries requirement sections only, so a Purpose edit cannot ride along in
this change's spec delta.

## Risks / Trade-offs

- **Image size** grows ~265 MB (uncompressed). Accepted: the alternative is
  every Go session paying a runtime download, and the layer is cached.
- **The pin will go stale** between bumps in a way the automated pins do not,
  since nothing rewrites it. Mitigated by the reminder line, which makes the
  drift visible on every refresh run rather than only at review time.
- **`GOTOOLCHAIN=auto` means the running toolchain may not be the pinned one.**
  Accepted and documented; `GOTOOLCHAIN=local` is the escape hatch.
- **New egress targets** (`proxy.golang.org`, `sum.golang.org`) in an image with
  no egress filtering. Consistent with the existing npm/PyPI/HashiCorp surface,
  and recorded in the threat model's runtime code-fetch bullet.
