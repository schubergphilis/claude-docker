## Why

The publishing pipeline (`docker.yml`) scans the image with grype and its
accepted-finding rules in `.grype.yaml`. The pull-request and scheduled scans
use Trivy with `.trivyignore`. The two accept findings differently: Trivy by
identifier across the whole image, grype by package, version and location. So
a change can pass every pull-request check and still fail the publishing scan.

#206 did exactly that. The pin refresh moved npm to 12.2.1, whose bundled
undici no longer matched a version-scoped `.grype.yaml` rule. The pull request
was green, because `.trivyignore` accepts the same CVE by ID. The first red
was the run on the default branch, and the v0.3.11-v0.3.13 tag runs that
should have published those releases failed in the same way.

Running the publishing pipeline on pull requests would catch this, but at the
cost of a second, two-architecture build per pull request. The pull-request
pipeline already builds and loads the image, so it can run grype on that
image at no extra build cost.

## What Changes

- `ci.yml`'s image scan also runs the publishing pipeline's grype scan after
  Trivy's: the same scan-action commit, over the image it already built and
  over the repository checkout, with `.grype.yaml`, at HIGH and above, and
  failing on findings with no fix as well, as the publishing scan does.
- The weekly scan (`image-scan.yml`) runs the same steps, so it keeps
  reporting what the next pull request will be blocked by.
- A unit test fails when the scan-action commit drifts from the one
  `docker.yml`'s pinned `mcvs-docker-action` runs, or when the two workflows'
  grype steps differ. Dependabot no longer bumps `anchore/scan-action` on its
  own.
- The scan documentation names both scanners and both accepted-finding files,
  says which findings each gate fails on, and says where `.trivyignore`'s
  expiry bounds an accepted risk and where it does not.

## Capabilities

- `image-vulnerability-scan`:
  - ADDED *The image is also scanned with the publishing pipeline's scanner
    and rules*.
  - ADDED *The publishing scanner's revision is checked against the publishing
    pipeline's*.
  - MODIFIED *Fixable high-severity findings block the merge; unfixed ones are
    reported*: unfixed findings still don't fail Trivy's gate, but the
    publishing scan's gate fails on those its rules don't accept.
  - MODIFIED *Accepted risk is recorded with a reason and an expiry*: a
    fixable finding both scanners report needs an entry in both files; one
    only grype reports, or with no fix, is bounded by `.grype.yaml` alone.

## Impact

- `.github/workflows/ci.yml`, `.github/workflows/image-scan.yml`,
  `.github/dependabot.yml`, `tests/test_grype_gate.py`, `docs/security.md`,
  `docs/maintenance.md`.
- A pull request now fails `Docker build (validate, no push)`, a required
  check, on any HIGH or CRITICAL finding the publishing scan would fail on,
  fixable or not. That includes a newly disclosed CVE with no fix in an
  unrelated pull request: it would fail the next publish anyway, and is
  accepted in `.grype.yaml` or fixed.
- No extra image build: a minute or two of scanning on top of the existing
  job.
