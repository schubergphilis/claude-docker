## 1. Image: install the pinned Go toolchain

- [x] 1.1 Resolve the version to pin: newest stable on go.dev that has already
      cleared the 7-day soak. At authoring time `go1.27.0` and `go1.26.7` were
      both tagged 2026-08-19 (one day old), so the pick is `1.26.6`
      (tagged 2026-08-13):

  ```bash
  curl -fsSL 'https://go.dev/dl/?mode=json&include=all' \
    | jq -r '[.[] | select(.stable) | .version] | .[0:6] | join(" ")'
  curl -fsSL 'https://api.github.com/repos/golang/go/commits/go1.26.6' \
    | jq -r '.commit.committer.date'
  ```

- [x] 1.2 Derive both hashes from the bytes, not from the feed, and check them
      against what the feed advertises:

  ```bash
  for a in amd64 arm64; do
    curl -fsSL "https://go.dev/dl/go1.26.6.linux-$a.tar.gz" -o "go-$a.tgz"
    sha256sum "go-$a.tgz"
  done
  # amd64 708effb774be8237570d0add163225abbdfaf4fca28b2611df167beba4feef89
  # arm64 d0507e9e9d7fe012aae570108cbd76c15de879e17130ab8cb90d4d7445cb1f2e
  # Both matched the .files[].sha256 values in go.dev's release JSON.
  ```

- [x] 1.3 Add `ARG GO_VERSION=1.26.6` plus `ARG GO_SHA256_AMD64` /
      `ARG GO_SHA256_ARM64` and the download-verify-extract `RUN` to the
      Dockerfile, **before** the npm-backed CLI layer (so a `claude-code` pin
      bump does not re-download the tarball). Arch selected with
      `dpkg --print-architecture`; anything other than `amd64`/`arm64` exits
      non-zero; ends with `/usr/local/go/bin/go version` as a build-time check.
- [x] 1.4 Add `PATH="/usr/local/go/bin:${PATH}:/root/go/bin"` to the existing
      `ENV` block, with the comment explaining why GOPATH's bin is appended last
      (volume-persisted and agent-writable — must not shadow system binaries).
- [x] 1.5 Update the header comment that claims every tool except nodejs is a
      generated `pins/` fragment, so it names Go as the second manual pin.

## 2. Pin tooling: keep Go visible without automating it

- [x] 2.1 Add `go_latest_stable()` to `update_pins.py` — newest stable from
      `https://go.dev/dl/?mode=json`, `go` prefix stripped, best-effort
      (returns `''` on any failure, like `ubuntu_current_digest()`), with the
      docstring recording *why* Go cannot join `TOOLS` (no publish dates).
- [x] 2.2 Add a `go` line to `print_reminders()`: parse `ARG GO_VERSION` from the
      Dockerfile, print pinned vs latest stable, and say that a bump means new
      hashes too. Three branches: drift, matches-latest, could-not-resolve.
- [x] 2.3 Confirm the reminder renders and the existing suite still passes:

  ```bash
  python3 -m unittest discover -s tests -p 'test_*.py' -q   # 47 tests, OK
  python3 -c 'import update_pins; update_pins.print_reminders()'
  # ⚠ go   pinned 1.26.6  latest stable → 1.27.0  (bump via the go.dev note…)
  ```

## 3. Docs

- [x] 3.1 README intro: preinstalled-tools line lists a version-pinned `go`, and
      the "language runtimes are not [preinstalled]" claim is narrowed to the
      other runtimes.
- [x] 3.2 README § Threat model, runtime code-fetch bullet: add
      `proxy.golang.org` module fetching, the `sum.golang.org` verification, and
      that default `GOTOOLCHAIN=auto` makes the pin a floor — with
      `GOTOOLCHAIN=local` as the refuse-and-fail-loudly setting.
- [x] 3.3 README: add the Go tarball to both sha256-verified download lists
      (threat-model hardening paragraph and § Updating pinned tool versions).
- [x] 3.4 README § Updating pinned tool versions: the manual-pins paragraph now
      covers Go, including why it stays manual and where the pin lives.
- [x] 3.5 Reword the `package-managers` spec Purpose so it no longer claims Go
      is deliberately excluded (rust/ruby/etc. still are). Applied directly to
      `openspec/specs/package-managers/spec.md` — a Purpose edit cannot ride
      in a spec delta.

## 4. Verify

- [x] 4.1 Lint: `hadolint --config .hadolint.yaml --failure-threshold warning
      Dockerfile` → clean.
- [x] 4.2 Dry-run the install step's shell logic outside Docker (same
      `dpkg --print-architecture` → hash-select → `sha256sum -c` → `tar -C` →
      `go version` sequence against the downloaded tarball) → reported
      `go version go1.26.6 linux/arm64`.
- [ ] 4.3 **Needs a host with Docker** — build to a disposable tag so your
      working `claude-code:local` is untouched, then verify the toolchain and the
      PATH ordering:

  ```bash
  docker build -t claude-code:go-test .
  docker run --rm claude-code:go-test go version          # expect go1.26.6
  docker run --rm claude-code:go-test go env GOROOT       # expect /usr/local/go
  docker run --rm claude-code:go-test bash -lc 'echo "$PATH"'
  # expect /usr/local/go/bin first and /root/go/bin last
  docker rmi claude-code:go-test
  ```

- [ ] 4.4 **Needs a host with Docker** — sha256 gate actually fires: flip one
      character of `GO_SHA256_AMD64` (or pass `--build-arg`) and confirm the
      build fails at `sha256sum -c` with nothing installed under `/usr/local/go`.

  ```bash
  docker build --build-arg GO_SHA256_ARM64=$(printf '0%.0s' {1..64}) \
    -t claude-code:go-tamper .   # expect: FAILED sha256 check, non-zero exit
  ```

- [ ] 4.5 **Needs an arm64 + an amd64 host (or CI)** — confirm both arches build
      and no Go binary fails with an exec-format error. CI's "Docker build
      (validate, no push)" job covers amd64 only; arm64 relies on a maintainer's
      local build, per the note in `.github/workflows/ci.yml`.
- [ ] 4.6 Optional end-to-end sanity in a real session: `go install` a small
      tool, exit the container, start a new one, and confirm the binary is still
      on PATH from `/root/go/bin` (persisted via `claude-code-root`).
