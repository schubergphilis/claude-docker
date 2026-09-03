## 1. Accepted-risk record

- [x] 1.1 Create `.trivyignore` with no entries and a header comment stating the entry
  contract: one finding per line as `<ID> exp:<yyyy-mm-dd>`, immediately preceded by a `#`
  comment giving the reason it was accepted. State in the same header that lowering
  `severity` or dropping the gate is not an accepted-risk mechanism, and that suppression is
  per-ID. Verify the file contains no uncommented lines
  (spec: *a recorded finding is suppressed*,
  *suppression does not widen beyond the recorded finding*)
- [x] 1.2 Add `tests/test_trivyignore.py` enforcing that contract on every future entry:
  stdlib only (`re`, `datetime`, `pathlib` — no PyYAML, so CI's existing
  `python3 -m unittest discover -s tests` step keeps working with no install and no workflow
  edit), fail-closed so a line the parser does not recognise is a failure rather than a skip,
  asserting each entry has a parseable `exp:` date and a non-empty reason comment directly
  above it. Verify by running the suite, and by asserting the test rejects three hand-built
  fixtures — an entry with no `exp:`, one with an unparseable date, and one with no reason
  comment — rather than only passing on the real file, which has no entries yet and would
  make a broken test look green
  (spec: *an entry with no expiry is rejected before it can suppress*)
- [x] 1.3 Assert in that test that expiry is checked for presence and parseability only, not
  for being in the future: an expired entry is Trivy's to act on (it stops suppressing and
  the finding blocks the gate again), and failing `Validate` on it too would report one
  lapsed acceptance as two unrelated red checks. Verify with a fixture carrying a
  long-past `exp:` date that the test accepts
  (spec: *an expired acceptance stops suppressing*)

## 2. PR gate in `docker-build`

- [x] 2.1 Resolve `aquasecurity/trivy-action`'s newest release to its commit SHA and add both
  scan steps to `ci.yml`'s `docker-build` job as
  `aquasecurity/trivy-action@<sha> # v<tag>`, matching the existing pin style. Verify the SHA
  belongs to that tag with `gh api repos/aquasecurity/trivy-action/tags` and that no tag or
  branch ref appears in the diff — `general.yml`'s zizmor audit reports a tag ref as
  `unpinned-uses`, so a tag would fail that job
  (spec: *the scanner reference is immutable*, *a mutable reference is rejected*)
- [x] 2.2 Add the advisory step first: `scan-type: image`, `scan-ref: claude-docker:ci`,
  `severity: HIGH,CRITICAL`, `scanners: vuln`, `exit-code: 0`,
  `trivyignores: .trivyignore`. Verify by inspection that it cannot fail the job, and
  that `vuln-type` is left unset so the action's `os,library` default keeps language packages
  in scope
  (spec: *an unfixed HIGH does not block*, *a vulnerable language package*,
  *a vulnerable OS package in the base image*)
- [x] 2.3 Set `scanners: vuln` explicitly on every invocation rather than relying on the
  default. An unset input exports no `TRIVY_SCANNERS`, so Trivy's own `vuln,secret` default
  applies and secret scanning runs against the whole image filesystem; a secret finding
  carries a severity but has no fixed version, so `ignore-unfixed` cannot filter it and it
  would block every merge under a check the spec defines as vulnerabilities only. Verify
  against `ScannersFlag.Default` in `pkg/flag/scan_flags.go` at the Trivy release the pinned
  action installs, and by asserting `scanners: vuln` is present on all four scan steps
  (spec: *a file matching a secret-detection rule does not fail the pipeline*)
- [x] 2.4 Add the gate step second, identical but with `ignore-unfixed: true` and
  `exit-code: 1`. Verify by inspection that the two steps differ in exactly those two inputs,
  so the advisory table and the gate cannot disagree about severity or suppressions
  (spec: *a fixable CRITICAL blocks*, *severities below the threshold do not block*,
  *a clean image passes*)
- [x] 2.5 Place both steps after the version-probe and smoke-matrix steps, and comment why
  the scan lives in `docker-build` rather than a job of its own: that job's local daemon is
  the only one holding the loaded `claude-docker:ci`, and `main`'s ruleset requires the
  `Docker build (validate, no push)` context, so a separate job would gate nothing until an
  operator edited the ruleset. Verify by reading the rendered job that no step between the
  build and the scan replaces or re-tags the image
  (spec: *the scanned artifact is the built artifact*)
- [x] 2.6 Cross-check every `with:` key used in 2.2 and 2.4 against the `inputs:` block of
  the action's `action.yaml` at the pinned SHA. Verify programmatically, not by eye: GitHub
  Actions silently ignores an unknown `with:` key, so a misspelled `ignore-unfixed` would
  leave the gate blocking on unfixed findings with nothing reporting the mistake

## 3. Scheduled scan

- [x] 3.1 Create `.github/workflows/image-scan.yml` following `pins-updater.yml`'s shape:
  `# yamllint disable rule:line-length` header, `---`, quoted `"on":`, a Monday `cron: 23 6
  * * 1` (one hour after the pins refresh, offset from Dependabot's window),
  `workflow_dispatch: {}`, top-level `permissions: contents: read`, and a `concurrency` group
  that does not cancel in progress. Verify it parses with PyYAML and that the parsed
  `permissions` grants nothing but `contents: read`
  (spec: *on-demand scan*)
- [x] 3.2 Give the job a checkout with `persist-credentials: false`, a buildx setup, and a
  `docker/build-push-action` build with `load: true`, `tags: claude-docker:ci`,
  `platforms: linux/amd64` and `cache-from: type=gha` — reusing the action SHAs already
  pinned in `ci.yml` rather than introducing second pins for the same actions. Verify every
  `uses:` SHA in the new file matches the one `ci.yml` uses for that action
  (spec: *An unchanged image is re-scanned on a schedule* — the build-not-pull clause)
- [x] 3.3 Add the same advisory and gate steps as 2.2/2.4 so the scheduled run blocks on
  exactly what the next PR will block on, and comment that a failing run is the whole
  notification — no issue is filed and no report is uploaded. Verify by diffing the two
  files' scan steps that severity, `scanners`, `ignore-unfixed`, `exit-code` and
  `trivyignores` are identical in both workflows
  (spec: *a CVE is disclosed against a static image*, *scheduled scan finding nothing*,
  and the same-threshold clause of *Fixable high-severity findings block the merge*)
- [x] 3.4 Set `cache-to` off (read-only cache use) so the scheduled run cannot evict or
  overwrite the layer cache that PR builds depend on, and comment it. Verify by inspection
  that `cache-to` is absent from the new workflow while `ci.yml`'s
  `cache-to: type=gha,mode=min` is unchanged

## 4. Docs

- [x] 4.1 Add a README subsection covering the scan: what it covers (OS and language
  packages across the whole image filesystem), that fixable HIGH/CRITICAL findings block a
  merge while unfixed ones are advisory, that `.trivyignore` entries need a reason and
  an expiry, and that `main` is re-scanned weekly with a failing run as the only
  notification. Verify the section renders with working relative links by inspection of the
  paths it names
  (spec: *README documents the policy*)
- [x] 4.2 State in that subsection why the scan is a step in the existing Docker build job
  rather than its own check, so a maintainer reading a red `Docker build (validate, no push)`
  knows a CVE is one of the things it can mean. Verify by inspection
  (spec: *README documents the policy*)
- [x] 4.3 Extend the Threat model section's build-time hardening sentence to say the image is
  scanned for known vulnerabilities and on what terms. Verify the existing
  sha256-verified download list and the npm `--ignore-scripts` claim are left textually
  intact — `go-toolchain`'s spec asserts the contents of that download list, and
  `package-managers`' asserts the runtime code-fetch bullet
  (spec: *threat model reflects the scan*)
- [x] 4.4 Confirm the README's pinned-tool-versions section still reads correctly beside the
  new subsection: it currently presents `npm audit signatures` as the npm supply-chain
  answer, and the new text must not imply that provenance verification covers known CVEs.
  Verify by reading both sections together
  (spec: the tarball-provenance clause of *The built image is scanned for known
  vulnerabilities*)

## 5. Verification

- [x] 5.1 Parse `ci.yml` and `.github/workflows/image-scan.yml` with PyYAML and assert the
  structure the tasks above claim: both scan steps present in `docker-build`, the
  advisory/gate input pairs, `scanners: vuln` on all four scan steps, and identical scan
  inputs across the two workflows. Note that `ci.yml`'s bare `on:` key parses to boolean
  `True` under YAML 1.1 while the quoted `"on":` in `image-scan.yml` parses to the string —
  do not key the assertions off it. No yamllint, actionlint or zizmor is available in this
  environment, so this parse plus 2.6's input cross-check are the only local backstops;
  `general.yml`'s yamllint and zizmor jobs are the real gate and run on the PR
- [x] 5.2 Record that the scan's runtime behaviour cannot be verified locally: neither docker
  nor trivy is available in this environment, so the first real evidence that the gate fires
  and the advisory step does not is CI's `docker-build` on the PR. Do not tick any task
  claiming an executed scan
- [x] 5.3 Run `python3 -m unittest discover -s tests -p 'test_*.py' -v` and confirm the whole
  suite passes with `test_trivyignore.py` included. This change adds no production Python, so
  a failure outside that new file is a pre-existing break and must be reported as such rather
  than fixed here; record the pre- and post-change test counts so the new tests are visibly
  additive
- [x] 5.4 Run `openspec validate scan-image-vulnerabilities --type change --strict
  --no-interactive` and confirm it passes
