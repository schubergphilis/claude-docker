## Why

[`README.md`](../../../README.md) is 458 lines / ~35 min; `## Auth model` and `## Threat model` are 42% of it.

A reader arriving to find out how to start a container has to scroll past an AWS SSO
walkthrough, a TLS-interception sidecar design, a pin-refresh runbook and a macOS
manual-test checklist to get there. None of that is wrong; it is just not front-door
material, and there is nowhere else for it to live because this repo has never had a
`docs/` directory.

This change moves the reference material out and leaves a quickstart. It is a
**relocation, not a rewrite** — the prose is moved verbatim so the diff reviews as a
move, and the density problems inside the moved text are a deliberate follow-up rather
than a second thing to review here.

The cost that is invisible until you grep for it: `openspec/specs/` carries live
requirements that locate this prose in README *by section name* — `` `claude-docker/README.md`
§ Threat model``, "the preinstalled-CLI list at the top of `claude-docker/README.md`".
Moving the prose makes those scenarios false, and per
[`CONTRIBUTING.md`](../../../CONTRIBUTING.md) the generated specs may not be hand-edited.
That is what makes this a spec change rather than a docs commit.

Closes [#76](https://github.com/schubergphilis/claude-docker/issues/76).

## What Changes

- **Add `docs/` with four files**, each 1,400–2,200 words, mapped onto distinct
  audiences: `auth.md` (someone wiring up credentials), `security.md` (someone doing a
  security review), `maintenance.md` (someone maintaining pins), `workflows.md`
  (someone customising their setup).
- **README keeps the quickstart** — intro, Install, Prebuilt image from GHCR, Container
  runtime, Usage, Credential opt-in, Session flags, Resuming sessions — plus Specs and
  License. The credential opt-in table stays deliberately: it is the most
  cross-referenced reference in the file and it is what people come back for.
- **A single `## Documentation` index** replaces the eleven moved sections, rather than
  eleven one-line stubs. One list to keep honest instead of eleven headings that exist
  only to point elsewhere.
- **Reword the location-pinning spec scenarios to be location-independent.** "the
  project's threat-model documentation" rather than repointing each scenario at a new
  `docs/<file>.md`. The requirements were always about *what the documentation says*;
  naming a file and a heading was incidental precision that made prose layout a
  spec-level concern. Location-independent wording means the next reorganisation needs
  no spec change at all.
- **Make the broken-link CI step blocking.** `.github/workflows/ci.yml` runs lychee with
  `continue-on-error: true`. That was defensible when every link was intra-README; with
  cross-file links between five documents, a silent break is the expected failure mode
  and the check has to be able to fail. Verified against `main` first: the link graph is
  already clean, so this turns red only on a real regression.
- **Fix the one user-visible pointer.** `run.sh:79` prints `See README "Private package
  registries".` from the `--help` heredoc; that section is now in `docs/auth.md`.

Not in scope:

- **Rewriting any moved prose.** `README.md:276` is ~500 words in a single bullet that
  starts on `npx`/`uvx`/`tfenv` and spends most of its length on `pnpm dlx` provisioning
  runtimes under four aliases — a subsection wearing a dash. `README.md:280` is the
  entire applied/not-applied hardening posture as one 2,184-character paragraph. Both
  are worth fixing and both land in `docs/security.md` unchanged here. A pure move is
  reviewable with `git diff --find-copies`; move-plus-rewrite is not, and mixing them
  makes the spec deltas harder to check. Move first, rewrite second.
- **An ADR directory.** `CONTRIBUTING.md:37-40` says architectural decisions live in
  each change's `design.md` and there is no separate ADR directory. That rule is about
  decision records and is untouched: `docs/` here is user-facing prose.
- **A docs site.** Four markdown files that render on GitHub. No generator, no config,
  no navigation build step.
- **`openspec/changes/archive/**`.** ~132 archived files mention README, ~20 of them by
  section. They are a historical record of what was true when the change shipped, and
  `lychee.toml` already excludes the path.

## Capabilities

### Modified Capabilities

- `go-toolchain`: the Go runtime code-fetch and build-time-pinning documentation
  requirements keep every claim they make about *content*; their scenarios stop naming
  `README.md` and its headings.
- `package-managers`: same treatment for the runtime code-fetch bullet and the
  preinstalled-CLI list.
- `image-vulnerability-scan`: the scan-policy documentation scenario stops naming the
  README specifically.
- `host-config-parity`: the `IS_SANDBOX` requirement's closing pointer to "the threat
  model in `claude-docker/README.md`" loses the filename.

No capability gains or loses a requirement, and no scenario changes what it asserts —
only where it says to look. `image-distribution` needs no delta: its requirement is that
the README documents the published image as an install path, and Install stays in
README. `cli-help` needs none either: no scenario asserts the body text of the help
output, only that each flag appears.

## Impact

- `docs/auth.md`, `docs/security.md`, `docs/maintenance.md`, `docs/workflows.md` — new.
- `README.md` — 458 lines to ~134; gains `## Documentation`.
- 23 intra-README anchors become cross-file links; 12 repo-relative links inside moved
  text gain a `../` prefix. `AGENTS.md` and `CONTRIBUTING.md` both link
  `README.md#threat-model` and are repointed in the same commit.
- `run.sh` — one `--help` line and one comment. `Dockerfile` and
  `.github/workflows/pins-updater.yml` — one comment each.
- `.github/workflows/ci.yml` — the lychee step loses `continue-on-error`. The
  markdownlint step keeps it: there is no markdownlint config in the repo, so it runs at
  defaults and MD013 fires on nearly every line of this project's prose style.
- `lychee.toml` is unchanged — its `**/*.md` glob already covers `docs/`.
- Every existing anchor slug survives, because the moved headings keep their text
  verbatim. A stale bookmark to `README.md#threat-model` breaks; a bookmark to the
  heading text finds it.
