## Context

`/root` is the persistent `claude-code-root` named volume (`run.sh:861`): it
survives `docker run --rm`, and it is shared across every session and every
workspace on the host. The agent runs as a dropped-privilege user whose passwd
entry is created with `-d /root`, so `/root` is both `HOME` and writable.

The image `PATH` reaches that agent verbatim. `entrypoint.sh:89` is
`exec runuser -u claude`, not `runuser -l` — no login shell, no
`/etc/profile`, no re-derivation of `PATH`. Whatever the `ENV` says is what a
session resolves commands against. That makes PATH ordering an image-level
security control, not a convenience setting, and it is why the existing
`go-toolchain` spec pins `/root/go/bin` last.

## Goals / Non-Goals

**Goals:**

- `GOROOT` / `GOPATH` / `GOBIN` readable from the process environment by
  non-Go tooling, with the same values `go env` would compute.
- Session-installed tools under `/root/.local/bin` runnable by name.
- No new way for one session to influence a later session's command
  resolution.
- The non-shadowing guarantee actually tested, not merely asserted in prose.

**Non-Goals:**

- No `GOCACHE` / `GOMODCACHE` / `GOFLAGS` / `GOPRIVATE` export — those have
  working defaults under `/root` that the volume already persists, and pinning
  them adds surface without a caller that needs it.
- No change to `GOTOOLCHAIN`, which stays at its default `auto`.
- No image-side installation into `/root/.local/bin`.

## Decisions

### Literal `/root`, not `${HOME}`

Docker does not define `HOME` during a build. `ENV GOPATH="${HOME}/go"` expands
against an empty string and bakes `GOPATH=/go` into the image — a directory
that does not exist, with no build-time error. `/root` is correct for both
paths through the entrypoint: the legacy `HOST_UID=0` fallback runs as root,
and the dropped-privilege user's passwd entry is created with `-d /root`.
`smoke/assert-in-container.sh` already asserts `HOME=/root` in both cells, so
the equivalence is enforced rather than assumed.

### Literal `/root/go/bin` for `GOBIN`, not `${GOPATH}/bin`

Docker resolves a variable reference in an `ENV` instruction against the value
from *before* that instruction, so `GOBIN="${GOPATH}/bin"` alongside
`GOPATH=/root/go` in the same `ENV` yields `GOBIN=/bin` — silently, and
pointing at a system directory.

An earlier draft worked around this with a separate `ENV GOHOME=/root/go`
instruction referenced by the next one. Rejected: `GOHOME` is not a Go variable,
`go env` ignores it, and it would ship in every session's environment inviting
`-e GOHOME=/other` overrides that do nothing (both dependants are baked at
build time). Spelling both paths out literally removes the workaround instead of
shipping it; the gotcha survives as a comment.

### `/root/.local/bin` goes behind every system path

The tempting framing is that a user-local prefix conventionally wins — that is
what it means on a normal workstation, where `~/.local/bin` is under the
control of the person typing the commands.

That does not transfer here. `/root/.local/bin` is written by an agent, not by
a person; nothing in the image ever writes to it, so by construction every byte
on that path arrives from a session. And because the directory is in the shared
volume, it is read by *later* sessions, in *other* workspaces, holding *other*
credentials. In first position it is a persistence primitive: one session writes
`/root/.local/bin/gh`, a later unrelated session runs `gh` and executes it.

There is nothing the image can check that distinguishes `/root/.local/bin` from
`/root/go/bin` — same volume, same writer, same lifetime. Treating them
differently would rest on the installer's intent, which the image cannot see.
So both go behind the system paths, `/root/.local/bin` first of the two on the
weak-but-harmless grounds that it is the more deliberate of the two
destinations. Tools installed either way stay runnable by name; the only
capability given up is overriding a system binary, which is precisely what the
requirement forbids.

### The requirement is renamed, not edited in place

The old title — "PATH ordering keeps GOPATH binaries non-shadowing" — and its
single `/root/go/bin` scenario would leave the new entry uncovered: a reader
greps the title, concludes the requirement is about `go install` output, and
misses that another writable directory is on PATH under the same guarantee. The
delta therefore removes the old requirement and adds a renamed one carrying
both directories and four scenarios, following the `REMOVED` + `ADDED` pattern
used by `2026-08-25-container-git-config-overlay`.

## Risks / Trade-offs

- **A tool that genuinely needs to override a system binary breaks.** Accepted:
  that is the guarantee, and the workaround (invoke by absolute path, or shadow
  it per-project) is available to a user who really wants it.
- **The smoke check pins `/usr/bin/git`.** If a future change moves `git` (e.g.
  a newer git installed under `/usr/local/bin`), the assertion fails loudly
  rather than silently stopping to test anything. That is the intended failure
  mode; update the expectation with the move.

## Open Questions

None.
