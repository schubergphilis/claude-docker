## Context

See `proposal.md` § Why for the motivation. The constraints that shape the approach:

- **The house action is not optional in spirit.** `schubergphilis/mcvs-general-action` and
  `schubergphilis/mcvs-pr-validation-action` already run here; `mcvs-docker-action` is the
  org's answer for building and publishing an image, and it bundles hadolint, dockle, dive and
  grype behind one `uses:`. Hand-rolling `build-push-action` + `login-action` would be a
  smaller workflow file and a larger divergence from the rest of the org.
- **The action's thresholds are not steerable from the caller.** It hardcodes
  `severity-cutoff: high`, `fail-build: true` and `only-fixed: false` for grype, and
  `failure-threshold: style` for hadolint — stricter than this repo's own `.hadolint.yaml`
  usage at `warning`. There is no input for any of them. The only levers a consumer has are
  the config files the tools read from the repo root, plus `dockle-accept-key`.
- **The scan runs before the push.** A failing grype scan does not just report; it stops the
  release from publishing. Anything grype flags and we cannot fix has to be recorded in
  `.grype.yaml` or the channel does not work at all.
- **Publishing is tag-gated inside the action.** Its push step carries
  `if: github.event_name == 'push' && contains(github.ref, 'refs/tags/')`. A consumer cannot
  publish on a branch push even if it wanted to.
- **`main`'s ruleset requires exactly `Validate` and `Docker build (validate, no push)`.** A
  new job's context gates nothing until an operator edits the ruleset — which, for this job,
  is the desired outcome rather than a gap.
- **`general.yml` runs a zizmor audit**, which reports a tag ref as `unpinned-uses` and a
  SHA whose trailing `# vX.Y.Z` comment does not resolve to that SHA as a mismatched pin.
  Both fire as code-scanning alerts on the PR.
- **The Dockerfile is already multi-arch.** Every third-party download branches on the build
  architecture against per-arch pins in `pins/*.env`. Nothing about the image is
  amd64-specific; only the pipeline was.

## Goals / Non-Goals

**Goals:**

- A published reference someone can pull, pinned to an immutable version tag.
- Cover the architectures the Dockerfile already supports, rather than letting the pipeline
  narrow the image's reach.
- Suppressions that are scoped by a property that stays true, not by an identifier that goes
  stale.
- Add no cost to the PR path.

**Non-Goals:**

- Replacing the Trivy gate in `ci.yml`. Two scanners with different databases and different
  triggers is redundancy, not duplication, and merging them is a separate decision.
- Making this job required. See Decisions.
- Making the first release happen. This change ships the mechanism; the tag is an operator
  action.

## Decisions

### Pin `v0.11.8-rc.1`, a pre-release

`platforms` — the input that makes multi-arch publishing possible — landed in the action as
`0067477 feat: build and scan linux/arm64 images (Closes #31)` on 2026-09-06. The newest
stable release, `v0.11.7` (2026-08-31), predates it. So the options were:

1. **Publish amd64-only on `v0.11.7`** and revisit. Rejected: it ships a worse artifact to a
   large fraction of users with no warning at pull time, and "revisit later" for a published
   tag means consumers pinned to an emulated image in the meantime.
2. **Pin the loose commit `0067477`.** This is what the branch did before this revision, with
   a `# v0.11.6` comment that did not match it — which is precisely what zizmor's two
   code-scanning alerts on `docker.yml:44` reported. A commit on the action's default branch
   is not a release; nothing stops it being rewritten and the version comment cannot be made
   truthful.
3. **Matrix over `[ubuntu-24.04, ubuntu-24.04-arm]`**, each leg building and scanning its own
   arch natively, then `docker buildx imagetools create` to weld a manifest list. This is the
   standard workaround when an action has no `platforms` input, and it has a real advantage:
   each leg scans the architecture it built, so arm64 would not go unscanned. Rejected here
   because the action's push step publishes `steps.meta.outputs.tags` itself — two legs would
   both push the same tag and clobber each other, so each leg would need
   `push-to-container-registry: ''` and a hand-rolled push of an arch-suffixed tag beside the
   action, plus a third job to assemble the list. That is three jobs and a bespoke tagging
   scheme to work around an input the action now has.
4. **Pin `v0.11.8-rc.1`** — the released tag containing that commit, resolving to
   `3323a5f9234b86b1faf3e6d43cca6d4ff984da47`. Chosen.

An rc is a real cost and worth naming: it can be superseded by a GA tag with different
behaviour, and the `platforms` default could still move before then. Two things bound it —
the tag is immutable and SHA-pinned like every other action here, and `platforms` is passed
explicitly rather than inherited from the default, so a default change cannot silently alter
what gets published. Bumping to `v0.11.8` when it ships is a one-line follow-up, and
Dependabot will open it.

### Publish two architectures, scan one

The action loads exactly one image into the docker store for dockle, dive and grype, because
only one can be, and it prefers `linux/amd64` since that needs no emulation. `linux/arm64` is
therefore built by buildx, pushed inside the manifest list, and never passed through those
three scanners.

This is the one genuinely uncomfortable part of the design, and it is accepted rather than
hidden, for three reasons. The two builds come from one Dockerfile with one set of pins, so
they differ only in the per-arch artifacts the pins already name and hash — there is no
arch-specific build logic for a scanner to catch. The findings that matter here are
overwhelmingly arch-independent (the go-module, python and npm-bundle exemptions in
`.grype.yaml` are all vendored-code findings that reproduce identically on both). And
`image-scan.yml`'s weekly Trivy scan is likewise amd64-only today, so this does not introduce
a blind spot the repo did not already have.

What makes it acceptable is that it is written down: in the workflow comment, in the README's
GHCR section, and as a requirement scenario that asserts the coverage gap is documented rather
than asserting it does not exist. If arm64 ever needs real scan coverage, option 3 above is
the route — as a scan-only matrix beside this job, not as a replacement for it.

### Suppress by type and location, never by CVE ID

Because the scan gates the push, `.grype.yaml` is load-bearing. Before any rules, the image
reported 105 High/Critical findings across ~63 advisory IDs; the three rules below take that
to 0 High/Critical remaining, with 202 of 531 matches ignored across 1962 packages.

Listing 63 CVE IDs would have been the obvious approach and is the wrong one: each entry goes
stale the moment upstream fixes it, nothing tells you when that happened, and the next CVE in
the same vendored dependency is unsuppressed and red again. Each rule is instead scoped to a
property that stays true for as long as the reason does:

| rule | scope | why nothing here can fix it |
| --- | --- | --- |
| `type: go-module`, `location: /usr/bin/**` | Go stdlib + vendored deps inside the prebuilt `gh`, `glab`, `task` binaries | nothing in this repo compiles Go; only an upstream rebuild moves it |
| `name: python`, `type: binary` | AWS CLI v2's bundled interpreter | moves with `pins/awscli.env`, not the Dockerfile |
| `location: **/node_modules/npm/**` | npm's own bundled dependency tree | arrives with the nodejs deb; only a Node bump moves it |

The `go-module` rule is scoped to `/usr/bin/**` specifically so it does **not** cover the Go
toolchain this repo pins itself at `/usr/local/go` — a stdlib CVE there is fixable by bumping
`ARG GO_VERSION`, and stays enforced.

The npm rule is the one that most deserved scrutiny, because it corrects an assumption worth
recording. After the two type rules, 8 High/Critical npm findings remained —
`brace-expansion@5.0.6`, `ip-address@10.2.0`, `tar@7.5.16`, `undici@6.26.0` — which look like
`pins/` problems and are not. `@anthropic-ai/claude-code` and `pnpm` both declare zero
dependencies and ship as bundled artifacts, so nothing under `pins/` influences their
resolution; all four are vendored inside the npm that the NodeSource deb carries; and no
released Node clears the set (24.20.0 fixes two but still ships `ip-address@10.2.0` and
`tar@7.5.19`). Scoping by **location** rather than by package name is what keeps this honest:
`**/node_modules/npm/**` covers npm's vendored tree at any prefix and does not match the
globals installed beside it, whose own dependencies stay enforced. Ignoring the four by name
would have masked them everywhere in the image, including openspec's real tree. The glob was
checked against `bmatcuk/doublestar` v2, the matcher grype actually uses.

`.dockleignore` gets the same treatment and stays at two entries, because only WARN and FATAL
gate at the action's `exit-level: warn`: `CIS-DI-0001` (no `USER`, by design — the entrypoint
needs root to chown `/root` to the host UID before dropping via `runuser`) and `DKL-DI-0005`
(fires on the `glab` layer, which `apt-get install`s a local `.deb` and so never populates
`/var/lib/apt/lists`; hadolint's `DL3009` keys on `apt-get update` alone, which is why the
same layer passes one and fails the other). `CIS-DI-0008` and `DKL-LI-0003` report as INFO,
cannot gate, and are deliberately left visible rather than suppressed — #17 changed the
Dockerfile for both, which turns out not to have been necessary.

### Advisory, and no PR trigger

These are two halves of one position: this job should cost the PR path nothing and block
nothing on it.

Not required, because `only-fixed: false` at a `high` cutoff means an upstream CVE disclosed
against ubuntu, node or Go turns the job red on a PR that never touched the image, with no
action available to that author. The repo already made this call once for `image-scan.yml`
and for the unfixed half of the Trivy gate.

No `pull_request` trigger, because `ci.yml` already answers "does the image build" on every
PR — with a `type=gha` cache this action does not use, and for one architecture where this
builds two. Measured on this PR: 1m10s cached against 3m0s/4m6s uncached, and that gap widens
with every layer added.

The tradeoff is real and is the reason `workflow_dispatch` stays: a change to `.grype.yaml`,
`.dockleignore` or the Dockerfile's scanner-visible surface is not validated by this job until
it lands on `main`. A branch that needs the answer first runs the workflow on demand. What
makes that acceptable rather than reckless is the ordering — `main` runs the full pipeline on
every merge, and a tag is only ever cut from a `main` that has already been through it.

## Risks / Trade-offs

- **The rc could be superseded or yanked.** Mitigated by the SHA pin (immutable), the explicit
  `platforms` value (a default change cannot alter the publish set), and Dependabot opening
  the bump to GA.
- **arm64 ships unscanned.** Bounded by one Dockerfile, one set of pins, arch-independent
  findings, and the pre-existing amd64-only Trivy coverage. Documented in three places rather
  than absorbed.
- **A red scan silently blocks a release.** The scan precedes the push, so a `v*` tag whose
  grype run fails publishes nothing. Stated in the README's GHCR section, since "the tag
  exists but the package does not" is otherwise a confusing failure.
- **QEMU-emulated arm64 builds are slow and can surface arch-specific build failures on
  `main` rather than on the PR.** Accepted as the price of not doubling PR cost;
  `workflow_dispatch` is the pre-merge escape hatch.
- **The scanner suppressions could hide a real regression.** Bounded by scoping: nothing is
  suppressed by CVE ID, the Go rule excludes our own toolchain, and the npm rule excludes the
  globals installed beside npm's bundle.
- **First push creates a private GHCR package.** It needs a one-time visibility flip, which is
  a manual step nothing in CI can do, so it is a task rather than a footnote.

## Migration Plan

None — nothing consumes this yet. `run.sh` keeps defaulting to `claude-code:local`, and the
published image is opt-in through the existing `CLAUDE_DOCKER_IMAGE` override. After merge:
push a `v*` tag, flip the package to public, then verify the pull path on both architectures.

## Open Questions

- Which `v*` tag is the first release, and does it follow this change or wait for a broader
  readiness pass? Recorded as an operator task, deliberately not decided here.
- Should `image-scan.yml`'s weekly Trivy run scan the *published* image once one exists,
  rather than rebuilding `main`? That becomes possible for the first time with this change and
  is left as a follow-up.
