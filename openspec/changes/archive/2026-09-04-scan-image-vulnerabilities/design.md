## Context

See `proposal.md` § Why for the motivation. The constraints that shape the approach:

- `ci.yml`'s `docker-build` job builds with `docker/build-push-action` and `load: true`,
  tagging `claude-docker:ci` into the runner's local daemon. Two existing steps carry a
  comment saying they must live in that job because it is the only one whose daemon holds
  that image. A scan is a third such step.
- `main`'s `main protection` ruleset requires exactly two status-check contexts: `Validate`
  and `Docker build (validate, no push)`. A new job's context is not in that list, so a new
  job cannot block a merge until an operator edits the ruleset.
- The image is never pushed anywhere. `docker-build` is named "validate, no push" and there
  is no registry copy of it to scan out of band.
- `general.yml` runs a zizmor audit through `mcvs-general-action`, which reports a tag ref as
  `unpinned-uses`. Every third-party action in the repo is therefore a commit SHA with a
  trailing `# vX.Y.Z`.
- The repo has both blocking CI steps (shellcheck, hadolint, unit tests, `npm audit
  signatures`, the version probes) and advisory ones (markdownlint, lychee, both
  `continue-on-error: true`). Both patterns are established, so choosing between them is a
  decision this design has to make rather than inherit.

## Goals / Non-Goals

**Goals:**

- One scanner, one policy, applied identically by the change-triggered scan and the scheduled
  scan, so the two cannot disagree about what blocks.
- Introduce no second version pin to maintain by hand.
- Keep the blocking surface actionable: a red pipeline should always have a next action for
  the person who sees it.

**Non-Goals:**

- Reporting anywhere other than the run's own job log — see `proposal.md` for why SARIF and
  issue-filing are excluded. Writing the table to `$GITHUB_STEP_SUMMARY` was considered for
  the scheduled scan, where a failing run is the notification, and cut: it needs `output:` to
  a file on both invocations (which silences the log), an `if: always()` publish step, and a
  second file to merge. The findings table is the last thing in the job log, one click from
  the run page.
- Scanning the repository's own source (`scan-type: fs`) or its IaC. This capability is about
  the image.
- Baselining or diffing findings between runs. The accepted-risk file is the only suppression
  mechanism.

## Decisions

### A step in `docker-build`, not a new job

The two hard reasons are in Context: only `docker-build` holds the loaded image, and only its
context is a required check. A new `scan` job would have to rebuild the image — doubling a
multi-minute build — and would then sit green-or-red beside the ruleset without gating
anything.

The cost is honest: the scan's failure is attributed to the `Docker build (validate, no
push)` check rather than to a check named for scanning, so a red build could be a broken
Dockerfile, a failing smoke cell, or a CVE. The step name makes it unambiguous in the log,
and buying a separate name would cost either the ruleset edit or the rebuild.

Ordering within the job: after the build, and after the version-probe and smoke steps. A pin
that ships a broken executable is a more fundamental failure than a CVE in it, and the smoke
matrix is the longer-standing signal; putting the scan last keeps a new failure mode from
masking the established ones.

### `aquasecurity/trivy-action`, not the org's `mcvs-docker-action`

`schubergphilis/mcvs-docker-action` is the org's container action, and it is the wrong fit
here on five counts:

- It scans with **grype** (`anchore/scan-action`), not Trivy. #46 names Trivy as the more
  widely used scanner internally.
- It **rebuilds the image itself** via its own `docker/build-push-action` step, so the smoke
  tests would run against one build and the scan against another, and CI would build twice.
- It runs **its own hadolint** at `failure-threshold: style`, where `validate` pins `warning`
  plus `.hadolint.yaml`. Two hadolint invocations with conflicting thresholds in one
  pipeline.
- It **defaults to pushing to ghcr**, which this repo deliberately never does.
- It additionally requires a `.dive-ci` config for its dive step.

It is a build-and-publish pipeline for a service image. This repo's image is built,
validated, and thrown away.

### Two invocations, one policy: gate then advisory

Trivy expresses "fail" through `exit-code` and "which findings" through `severity` /
`ignore-unfixed`. One invocation cannot both fail on the fixable subset and print the unfixed
remainder, so there are two:

1. **Advisory** — `severity: HIGH,CRITICAL`, `exit-code: 0`. Prints the full HIGH/CRITICAL
   picture, fixable and not.
2. **Gate** — `severity: HIGH,CRITICAL`, `ignore-unfixed: true`, `exit-code: 1`.

Advisory first so its output is already in the log when the gate fails. The gate's table is
then exactly the actionable subset.

`exit-code: 0` rather than `continue-on-error: true` for the advisory step, despite
`continue-on-error` being the repo's precedent for markdownlint and lychee: those actions
have no exit-code control, whereas Trivy does, and `continue-on-error` additionally decorates
the step with a failure annotation that would read as a problem when the step is doing its
job. The duplication between the two tables is deliberate and small.

`vuln-type` stays at the action's `os,library` default — that default is precisely the
whole-filesystem coverage the spec requires, so overriding it would only risk narrowing it.

`scanners: vuln` is set **explicitly** on every invocation. Leaving it unset does not mean
vulnerabilities only: the action exports no `TRIVY_SCANNERS` when the input is empty, so
Trivy's own default applies, and that default is `vuln,secret` (`ScannersFlag.Default` in
`pkg/flag/scan_flags.go` at v0.70.0, the release the pinned action installs). Secret
scanning would then run against the whole image filesystem, where the Go distribution's
crypto test data and vendored `node_modules` test fixtures routinely carry dummy keys. A
secret finding is not a vulnerability, so `ignore-unfixed` cannot filter it — nothing about
a matched key has a "fixed version" — and it would count against `severity: HIGH,CRITICAL`
with `exit-code: 1` and block every merge under a check the spec defines as vulnerabilities
only.

The image is addressed as `scan-type: image` plus `scan-ref`, not `image-ref`: the action's
own metadata labels `image-ref` "(for backward compatibility)" and its entrypoint merely
copies it over `scan-ref`. `scan-type` is set explicitly even though `image` is its default,
because it is what gives `scan-ref` its meaning. Trivy resolves an unqualified reference
against the local daemon first, which is where `docker-build` loaded it.

### The Trivy binary version rides the action pin

`trivy-action` has a `version` input defaulting to a specific Trivy release. This design
leaves it unset. Pinning it explicitly would create a second version to bump by hand, with
nothing watching it — the exact failure mode `update_pins.py`'s reminders exist to prevent,
and this repo has no mechanism that would cover a version buried in a workflow input.
Unset, the binary version is a property of the action SHA, which Dependabot's
`github-actions` ecosystem already bumps weekly.

The vulnerability database is fetched at scan time regardless, which is the point: new CVE
data must reach an unchanged image.

### Plain `.trivyignore`, with a test enforcing the entry contract

The spec makes a reason and an expiry mandatory per entry. **Trivy enforces neither.** In
`pkg/result/ignore.go` at v0.70.0, a line whose fields do not include an `exp:` token yields
a zero `ExpiredAt`, which suppresses the finding forever; the YAML format behaves the same
way when `expired_at` is absent ("the ignore finding is always valid"). So whichever format
is chosen, the mandatory part of the requirement needs something outside Trivy to hold it up,
or it is decoration.

That reduces the format choice to how cheaply it can be validated:

- **Plain** — line-oriented, so a strict fail-closed validator needs nothing but `re` and
  `datetime`. It can live in `tests/`, where CI's existing
  `python3 -m unittest discover -s tests` step picks it up with no workflow edit. That step
  documents itself as needing "no install, no third-party action (the suite imports only the
  standard library)", a property worth keeping.
- **YAML** — the reason becomes a first-class `statement` field rather than a comment, but
  validating it means PyYAML, which the unit-test step deliberately does not have, and Trivy
  documents the format as experimental.

Plain wins: the `statement`-versus-comment advantage evaporates once a validator enforces the
comment's presence, and it is the only option that keeps the enforcement stdlib-only. One
genuinely useful Trivy behaviour comes with it — a *malformed* `exp:` date makes the parser
skip the entry entirely rather than treat it as unexpiring, so a typo'd date fails closed and
the finding keeps blocking.

The path is passed explicitly via the action's `trivyignores` input rather than relying on
Trivy's auto-detection of `.trivyignore`, on both the advisory and the gate invocation. Two
properties of that input are load-bearing. The action **errors if the named file does not
exist**, so renaming or deleting the file fails the build instead of silently scanning with
no suppressions. And it `cat`s the file into the job log on every run, so a suppression is
visible to anyone reading a scan, not only to someone who thinks to open the file. Passing it
to the advisory step too keeps a suppressed finding from reappearing there and reading as
unsuppressed.

The validator asserts presence and parseability of the expiry, **not** that the date is still
in the future. An expired entry is Trivy's job: it stops suppressing, and the finding blocks
the gate again. A test that failed on expiry would turn every lapsed acceptance into a red
`Validate` job as well, reporting the same thing twice in different places.

### Weekly, Monday 06:23 UTC

One hour after `pins-updater.yml`'s Monday 05:23. Deliberate adjacency: the week's pin-refresh
PR and the week's CVE report land in the same window, so an operator triaging the pins diff
already knows whether it clears a finding. Offset from Dependabot's window for the same reason
`pins-updater.yml` is.

Daily was considered and rejected: it would cut worst-case detection latency from seven days
to one, at the cost of a rebuild-and-scan every day for a developer-tooling image that ships
no service. Weekly matches the cadence at which anything actually gets acted on here.

### The scheduled scan is a separate workflow file

Not a second trigger on `ci.yml`. A `schedule` trigger there would run the whole pipeline —
`validate`, the smoke matrix — or need `if:` guards on every job to avoid it. A separate
`image-scan.yml` also keeps the scheduled run's name distinct in the Actions list, which
matters when a failing run *is* the notification.

It duplicates the build step from `docker-build`. That duplication is accepted rather than
factored into a reusable workflow: the two builds differ (the scheduled one needs no smoke
matrix and no version probes), and a reusable workflow would put a third indirection between
the ruleset's required context and the thing it runs.

The duplicated build is deliberately **not** a copy: it takes `cache-from: type=gha` and no
`cache-to`. The scheduled run consumes the layer cache and must not write to it. PR builds
import from the cache scope `main` writes, and the repo-wide Actions cache is a fixed budget
under LRU eviction — a second weekly writer of multi-gigabyte layers can evict entries PR
builds were relying on, which shows up as slower builds with nothing pointing at the cause.
Copying `ci.yml`'s `cache-to: type=gha,mode=min` across is therefore the one edit to this
file that looks like tidying up and is not.

## Risks / Trade-offs

- **The gate goes red on a fixable CVE in a PR that did not introduce it** → this is the
  design working as intended, and it is why `.trivyignore` exists with a mandatory expiry.
  The scheduled scan is the early-warning channel that should normally surface such a finding
  before a contributor meets it.
- **Ubuntu ships the fix later than the CVE is disclosed** → `--ignore-unfixed` covers exactly
  this window: while no fix exists the finding is advisory, and it becomes blocking the moment
  a fixed version is published. The trade-off is that the blocking moment is not chosen by us.
- **Trivy's database fetch from ghcr.io fails** → a new CI failure mode, unrelated to the
  code. The action retries and caches the DB; a hard outage fails the build with an obvious
  error rather than silently passing. Fail-closed is the right side to err on for a scanner,
  and this is not a novel exposure — the pipeline already depends on ghcr for actions and on
  npm for the signature audit.
- **A red `Docker build (validate, no push)` no longer implies a build problem** → the step
  name disambiguates in the log. Accepted in exchange for gating without a ruleset edit; see
  the first decision.
- **Scan time is added to the critical path of every PR** → two scans of one already-local
  image, with a cached DB. It lands after the smoke matrix, which is by far the longer step.
- **An operator can silence a finding by editing `.trivyignore` with no review** → the file
  is version-controlled and `main` requires a PR with one approval, so a suppression is
  reviewed like any other change. The expiry is what stops a reviewed suppression becoming
  permanent, and the entry-contract test stops it being added without one.
- **The entry-contract test constrains `.trivyignore` to a subset of what Trivy accepts** →
  the validator is fail-closed, so a legitimate construct it does not recognise (a `paths:`
  scoping, say) fails `Validate` until the validator learns it. Accepted deliberately: the
  alternative is a permissive validator, which cannot distinguish an unrecognised construct
  from a malformed entry and so cannot enforce the requirement at all.

## Migration Plan

Additive; nothing to migrate. The rollback is reverting the commit — no state, no secret, no
ruleset change, and no operator action required for the scan to gate, which was the point of
putting it inside `docker-build`.

One caveat for the first run: neither scan has ever run against this image, so the first PR
may surface a backlog of pre-existing fixable findings that has nothing to do with its own
diff. If that happens the honest options are to bump the offending pins in the same change or
to record time-boxed accepted-risk entries — not to weaken the threshold, which the spec
rules out as an accepted-risk mechanism.
