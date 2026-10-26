## Why

The publishing pipeline (`docker.yml`) is the only place that runs dockle, dive
and grype, and it does not run on pull requests. So a pull request can break it
and still merge green. #206 did exactly that: the pin refresh moved npm to
12.2.1, whose bundled undici no longer matched a version-scoped `.grype.yaml`
rule. The pull-request pipeline stayed green, because its Trivy gate accepts the
same CVE by ID across the whole image. The first red was the run on the default
branch, and the v0.3.11-v0.3.13 tag runs that should have published those
releases failed in the same way.

The on-demand trigger only helps someone who already suspects the change
touches the scan, and an automated pin refresh never does.

## What Changes

- The publishing pipeline runs on every pull request. It builds, lints and scans
  the image as it does on the default branch, and never publishes from a pull
  request.
- It stays out of the merge path: it is not a required status check, so an
  unfixed upstream CVE can turn it red without blocking an unrelated pull
  request.
- A newer run for the same pull request cancels the one in progress, since a
  pull-request run never publishes. Runs on branches and tags are still never
  cancelled.

## Capabilities

- `image-distribution`: MODIFIED *The publishing pipeline does not gate merges*
  (runs on pull requests without publishing and without being a required check;
  a superseded pull-request run is cancelled; scenarios for a pull request, a
  pin bump that invalidates an accepted-finding rule, and an unfixed upstream
  vulnerability).

## Impact

- `.github/workflows/docker.yml`: a `pull_request` trigger, and cancellation of
  superseded pull-request runs.
- CI time: every pull request also pays for a two-architecture build, the second
  under QEMU. This is the cost the old requirement avoided.
