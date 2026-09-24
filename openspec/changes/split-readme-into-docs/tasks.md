## 1. Spec & design

- [x] 1.1 Proposal: why the front door is a 35-minute read, what moves, what deliberately
  stays, and why the spec deltas — not the prose move — are the substance of the change
- [x] 1.2 Design: where the seam falls at `README.md:116`, the audience-based grouping and
  the three groupings rejected, why relocation is kept separate from rewriting, and why the
  spec scenarios go location-independent rather than being repointed
- [x] 1.3 Spec deltas for `go-toolchain`, `package-managers`, `image-vulnerability-scan` and
  `host-config-parity`, each a `## MODIFIED Requirements` block restating the full
  requirement and every one of its scenarios. No requirement is added or removed and no
  scenario changes what it asserts — only where it tells the reader to look
- [x] 1.4 Confirm no delta is owed by `image-distribution` (its requirement is that the
  README documents the published image as an install path, and `## Install` stays) or by
  `cli-help` (no scenario asserts the body text of the help output)

## 2. The move

- [x] 2.1 Establish the link-check baseline **before** moving anything: the repo's markdown
  link graph must already be clean, otherwise task 4.2 inherits someone else's breakage and
  cannot honestly be made blocking
- [x] 2.2 `docs/auth.md` — `## Auth model` and its four subsections (`README.md:152-261`),
  verbatim under an `# Auth model` H1
- [x] 2.3 `docs/security.md` — `## Threat model` (`266-279`) and `## Image vulnerability
  scanning` (`381-407`), verbatim
- [x] 2.4 `docs/maintenance.md` — `## Updating pinned tool versions` (`280-306`) and `## CI
  smoke tests` with its macOS checklist (`408-447`), verbatim
- [x] 2.5 `docs/workflows.md` — `## Host config parity` and its three subsections
  (`117-151`), `## File ownership` (`262-265`), `## Git worktrees` (`307-331`), `## Pasting
  images` (`332-335`), `## Split-pane agent teams` with its iTerm2 subsection (`336-354`),
  `## Extending the image` (`355-380`), verbatim
- [x] 2.6 README keeps `1-116` and `448-456`, and gains a `## Documentation` index of four
  links after `### Resuming sessions across workspaces`. The credential opt-in table stays
  where it is — it is the most cross-referenced reference in the file
  (spec: *the preinstalled-CLI list at the top of the project's front-page documentation*)
- [x] 2.7 Verify the move is a move: total word count across the five files matches the 8,426
  README started at, and no heading text changed, so every anchor slug survives

## 3. Links and pointers

- [x] 3.1 Rewrite 23 intra-README anchors. Same-file targets stay bare; `docs/*` siblings
  take a bare filename (`security.md#threat-model`, no `../`); pointers back at the
  quickstart take `../README.md#…`
- [x] 3.2 Prefix `../` onto the 12 repo-relative links that travel with the moved text
  (`pins/`, `update_pins.py`, `.trivyignore`, `smoke/*.sh`, `tests/*`, the workflow files,
  `examples/settings.docker.json` ×2). The six in retained sections are left alone
- [x] 3.3 Repoint the two inbound anchors — `AGENTS.md` and `CONTRIBUTING.md` both link
  `README.md#threat-model` — and widen their "everything is in README" sentences to name
  `docs/`
- [x] 3.4 `README.md:154` says "see Credential opt-in **above**", which stops being true once
  it lives in `docs/auth.md`. Drop the word. `:140` and `:237` say "above" about things
  inside their own section and travel with it
- [x] 3.5 `run.sh:79` prints `See README "Private package registries".` from the `--help`
  heredoc — a user-visible pointer at a section that moved. Point it at `docs/auth.md`
- [x] 3.6 Comments that describe README by content: `.github/workflows/pins-updater.yml`
  (→ `docs/maintenance.md`), `run.sh:784` (→ `docs/security.md`), `Dockerfile:41`
  (→ `docs/maintenance.md`). `docker.yml:57` ("the README's GHCR section") and `run.sh:513`
  ("the README table" = Session flags) stay correct and are left alone

## 4. Verification

- [x] 4.1 Re-run the link check across all five documents: every relative path resolves and
  every `#fragment` matches a heading in the file it names
- [x] 4.2 Drop `continue-on-error: true` from `ci.yml`'s "Broken relative links" step, now
  that a silent cross-file break is the expected failure mode. Markdownlint keeps its
  `continue-on-error`: the repo has no markdownlint config, so it runs at defaults and MD013
  fires on nearly every prose line here
- [x] 4.3 `bash run.sh --help` renders and names `docs/auth.md`; `shellcheck` clean
- [x] 4.4 Unit tests still pass — they do not read the docs, so this confirms the change
  stayed inside the prose
- [x] 4.5 `openspec validate split-readme-into-docs --strict` passes
- [ ] 4.6 Open the follow-up for the density fix: `README.md:274`'s 3,246-character bullet
  wants the `pnpm dlx` half split out under its own heading, and `:278`'s hardening paragraph
  wants an applied/not-applied table. Both land in `docs/security.md` unchanged here
