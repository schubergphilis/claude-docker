## Context

#219 settled the question: Go does not fit the vision page, so it leaves the
base image. This change is the mechanics.

## Decisions

- **Remove outright, no opt-in build arg.** An `ARG INSTALL_GO` would keep the
  pin, the reminder and the CVE upkeep in the repo for a tool the base image
  should not carry. The child-image recipe is the opt-in.
- **Keep the PATH-ordering rule.** `/root/.local/bin` (uv tool, `pip --user`)
  lives in the persistent volume and must stay after the system paths, so the
  requirement moves to `package-managers` rather than disappearing with Go.
- **Keep the grype `/usr/bin/**` go-module rule.** It covers Go code vendored in
  the prebuilt gh, glab and task binaries, which has nothing to do with the
  toolchain. Only its comment changes.
- **Leave the `.trivyignore` golang.org/x/net entry.** The finding it covers is
  in the prebuilt `gh`, not the toolchain.

## Risks / Trade-offs

- Anyone running `go` in a session breaks on upgrade. Mitigation: a release note
  and a copy-paste recipe, and the change is announced on #219.
- A child image has to carry its own Go pin and checksum. The recipe states that
  and uses the same sha256-verified tarball install the base used.

## Open Questions

- The Purpose paragraphs of `package-managers` ("Go is the one exception,
  shipped in the image under its own `go-toolchain` capability") and
  `version-pin-refresh` ("the same reason `go` stays manual (see
  `go-toolchain`)") still mention Go. OpenSpec deltas cannot edit a Purpose,
  and `openspec/specs/` is generated: should the archive step regenerate them,
  or is a one-off follow-up needed?
