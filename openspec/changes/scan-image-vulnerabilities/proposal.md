## Why

CI proves the pinned tools *install* (`docker-build`) and, for the npm-backed ones, that the
tarball came from npm's keyring (`npm audit signatures`). Nothing asks whether the versions
it just shipped carry a **disclosed CVE** — not in the tools, not in their transitive
dependencies, not in the Ubuntu base image's system packages.

The existing freshness signals are a mismatched proxy for that question. `update_pins.py`'s
`⚠ needs your eyes` block and `pins-updater.yml` report when something *newer* exists, but a
pin can be perfectly current and still be vulnerable, and a CVE disclosed against an image
whose pins never moved produces no signal at all. Resolves
[#46](https://github.com/schubergphilis/claude-docker/issues/46).

## What Changes

- Add **two Trivy scan steps** to the existing `docker-build` job in
  [`ci.yml`](../../../.github/workflows/ci.yml) — one advisory, one blocking — scanning the
  `claude-docker:ci` image that job already loaded. Steps, not a new job: `docker-build` is
  the only job whose local daemon holds that image, and `main`'s ruleset requires exactly the
  `Validate` and `Docker build (validate, no push)` contexts — so a step gates merges on the
  checks that already exist, where a new job would not gate anything until an operator edits
  the ruleset. Two invocations because Trivy cannot both fail on the fixable subset and
  report the unfixed remainder in one pass; `design.md` has the mechanics.
- Add **`.github/workflows/image-scan.yml`**: a weekly cron plus `workflow_dispatch` that
  rebuilds `main`'s image and scans it. This is the case a PR scan structurally cannot cover
   — a CVE disclosed against an image nobody has touched. It rebuilds rather than pulls
  because this repo never pushes the image anywhere.
- **Fail on HIGH and CRITICAL with a fix available; report unfixed ones without failing.**
  An unfixed upstream CVE cannot be actioned by the author of an unrelated PR, so blocking on
  one turns a required check red for everyone until someone silences it. Both scans apply the
  same policy, so the scheduled run tells the operator what the next PR will block on.
- Add **`.trivyignore`** as the accepted-risk record, and a stdlib-only test that enforces its
  entry contract. Every entry carries a reason and an expiry date, so an accepted risk lapses
  back into a failure instead of becoming permanent silence — and because Trivy treats an
  entry with no expiry as valid indefinitely, the test is what makes "mandatory" true.
- Scan the **whole image filesystem** — OS packages and language packages — not just the OS
  layers. The npm-installed CLIs and the Go toolchain are exactly what `npm audit signatures`
  does not cover: it establishes tarball provenance, not that the code inside is free of
  known CVEs. Vulnerabilities only; no secret or misconfiguration scanning.
- SHA-pin `aquasecurity/trivy-action` by commit with a trailing `# vX.Y.Z` comment, the
  treatment every third-party action in this repo already gets. `general.yml`'s zizmor audit
  reports a tag ref as `unpinned-uses`, so a tag would fail that job.
- Document the scan in [`README.md`](../../../README.md): the fail policy, the
  `.trivyignore` contract, and the scheduled run. The Threat model section's
  build-time hardening paragraph currently makes no claim about CVE scanning either way.

Not in scope:

- **Pin freshness and version drift** — `version-pin-refresh`, the in-progress
  `schedule-pin-refresh` change, and #45. #46 is explicitly independent: that work asks
  whether a pin has drifted from upstream, this asks whether what is shipped is vulnerable.
- **Opening an issue or uploading SARIF** when the scheduled scan finds something. A failing
  run is the whole notification mechanism, deliberately: the alternatives need `issues: write`
  or `security-events: write`, and turning on Code Scanning alerts for a public repo is a
  separate visibility decision.
- Pushing the image to a registry; secret and misconfiguration scanning; auto-remediation of
  findings; network egress filtering.

## Capabilities

### New Capabilities

- `image-vulnerability-scan`: CI scans the built image for known vulnerabilities in its OS
  and language packages, with a documented fail threshold, an expiring accepted-risk record,
  and a scheduled re-scan of an unchanged image.

### Modified Capabilities

None. `version-pin-refresh` keeps every requirement it has — this change adds a second,
orthogonal signal rather than altering how pins are resolved, reported or verified. The
threat-model requirements in `go-toolchain` and `package-managers` are about *runtime*
code-fetch paths and the sha256-verified download list, neither of which this touches.

## Impact

- `.github/workflows/ci.yml` — two new steps in `docker-build`, advisory then gate.
- `.github/workflows/image-scan.yml` — new.
- `.trivyignore` — new; empty of entries at first, with the contract in a header comment.
- `tests/test_trivyignore.py` — new; enforces that contract. Stdlib only, so CI's existing
  no-install unit-test step needs no change.
- `README.md` — new subsection under CI documentation, plus a build-time hardening line in
  Threat model.
- New third-party CI dependency: `aquasecurity/trivy-action`. Dependabot's
  `github_actions` ecosystem is already configured, so it will be kept current like the rest.
- Trivy downloads its vulnerability database from ghcr.io at scan time; a database-fetch
  outage is a CI failure mode this change introduces.
