## Where the seam falls

README already has a clean break at line 118. Everything above it answers "how do I get
this running": the intro and preinstalled-tool line, `## Install` with the GHCR path,
`## Container runtime`, and `## Usage` with its three subsections. Everything below is
reference material consulted once, or during an incident, or never.

The credential opt-in table is the deliberate exception. It sits at `README.md:85-99`,
inside the quickstart, and it is the single most cross-referenced thing in the document
— five of README's own anchors and most of the `--help` output orbit it. Moving it into
`docs/auth.md` would be defensible on the "reference material" rule and wrong in
practice, because it is what a returning user opens README to find. It stays.

`## Specs` and `## License` stay too: four lines each, and License carries the
warranty disclaimer, which belongs on the front door.

## Grouping the four files

The grouping is by audience, not by topic adjacency:

| File | Audience | Words |
|---|---|---|
| `auth.md` | wiring up credentials for the first time | ~2,175 |
| `security.md` | reviewing whether this is safe to run | ~1,900 |
| `maintenance.md` | maintaining the pins, or debugging CI | ~1,390 |
| `workflows.md` | customising an already-working setup | ~1,420 |

Each lands at a readable page length. The alternative groupings considered and rejected:

- **One `docs/reference.md`.** Solves nothing — it is the same 7,000 words with one
  fewer heading level.
- **One file per README section (eleven files).** Some would be four lines. `## Pasting
  images` is three sentences; it has no standalone existence.
- **Split by `##` depth — top-level sections stay, subsections move.** Cuts `## Auth
  model` away from its own four subsections, which is the one grouping in README that is
  genuinely coherent.

`File ownership` (four lines) goes to `workflows.md` rather than `security.md` even
though the threat model links to it, because it describes a thing the container does to
your files on every run, not a risk you accept.

## Relocation, not rewriting

The moved text is byte-identical apart from link targets and one word. That constraint
is the point: a reviewer can run `git diff --find-copies-harder` and confirm nothing was
smuggled in. The moment prose is reworded in the same commit, the reviewer has to read
all 7,000 words to know that, and the four spec deltas — which are the part that can
actually be wrong — get read last and least carefully.

Two defects ride along unfixed as a result, both in `docs/security.md`:

- The `**Runtime code-fetch:**` bullet, 3,246 characters. It opens on `npx`/`uvx`/`tfenv`
  and then spends ~350 words on `pnpm dlx` provisioning runtimes under four aliases.
  That second half is a subsection wearing a dash.
- The hardening paragraph, 2,184 characters, listing what is applied and what is not as
  one run-on sentence sequence. It wants a two-column table.

Both are recorded as follow-up. Neither is made worse by moving.

## Location-independent spec wording

Nine scenarios across four capabilities currently assert that a reader "inspects
`claude-docker/README.md` § Threat model" or "the preinstalled-CLI list at the top of
`claude-docker/README.md`". Two ways to fix them:

1. **Repoint each at its new home** — `docs/security.md` § Threat model.
2. **Drop the location** — "the project's threat-model documentation".

(2), for three reasons. The requirements were never about file layout; every one of them
is a claim about *what the documentation says*, and the filename was incidental
precision. It makes the specs survive the next reorganisation for free, which matters
because this is the second time prose layout has forced a spec edit. And it removes a
class of silent staleness: a scenario naming a heading goes false when someone renames
the heading, and nothing in CI notices — whereas "the project's threat-model
documentation" is false only when the documentation actually stops saying the thing,
which is the condition the scenario exists to detect.

The cost is a scenario that is marginally harder to verify by hand: a reviewer has to
know where the threat model lives. `README.md`'s `## Documentation` index answers that
in one hop.

Three scenario *titles* keep the word README — "README threat model covers the Go fetch
paths" and two siblings — because OpenSpec has no way to express a scenario rename. A
`MODIFIED` requirement replaces the whole block and `validate --strict` refuses to drop
a scenario the current spec still has, so a retitle reads as a deletion; `REMOVED` plus
`ADDED` of the same requirement name is rejected outright. The titles are labels and the
`WHEN`/`THEN` bullets are the assertions, so the requirement is location-independent in
every part that is checked. Retitling them means renaming the requirements too, which
churns four capabilities' spec history for cosmetics.

Incidentally fixed along the way: every one of these references writes
`claude-docker/README.md`, which is the containing *directory* name prefixed onto the
filename, not a repo-relative path. Nothing has ever resolved it. Instances outside the
four reworded scenarios are left alone rather than swept, so this change's spec diff
stays about this change.

## The link check has to be able to fail

`.github/workflows/ci.yml` runs lychee `--offline --include-fragments` over `**/*.md`
with `continue-on-error: true`. The `docs/` glob is already covered, so no config change
is needed — but the failure mode changes character. Today every link is intra-README:
break one and the anchor is a few hundred lines from its target, and you probably
noticed while editing. After the split, 23 links cross a file boundary, and the way you
break one is by renaming a heading in a file you were not looking at.

An advisory check that nobody reads is a check that does not exist. Dropping
`continue-on-error` from that step is a one-line change with a real gate behind it: it
was verified clean against `main` before the split, so the first red run is a real
regression rather than inherited debt.

Markdownlint stays advisory. There is no markdownlint config in the repo, so it runs at
stock defaults, and MD013 (80-character lines) fires on essentially every prose line
here. Making it blocking would mean either reflowing the entire corpus or adding a
config to disable the rules it violates — a separate decision, and not this change's.

## What breaks for a reader, and what does not

Every moved heading keeps its exact text, so every anchor slug survives; only the file
in front of the `#` changes. Concretely:

- A link to `README.md#threat-model` (two in this repo, both fixed here; unknown many
  outside it) breaks.
- A GitHub search, a bookmark to the heading text, or a reader following `##
  Documentation` finds it.

Preserving the old anchors would mean keeping eleven stub headings in README, which
gives a reader a table of contents where every entry is a redirect. The index is
honest about there being four places to look.
