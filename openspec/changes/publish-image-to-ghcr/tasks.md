## 1. Publishing workflow

- [x] 1.1 Add `.github/workflows/docker.yml` invoking `schubergphilis/mcvs-docker-action` with
  `images: ghcr.io/${{ github.repository }}` and `token: ${{ secrets.GITHUB_TOKEN }}`, under
  top-level `permissions: contents: read` + `packages: write`. Verify `packages: write` is the
  only write scope granted — the action logs in to ghcr with this token and nothing else here
  needs to write
  (spec: *the image is published on a version tag*)
- [x] 1.2 Trigger on `push` with `branches: [main]` and `tags: [v*]`, plus
  `workflow_dispatch`. Verify against the action's own source at the pinned SHA that its push
  step carries `if: github.event_name == 'push' && contains(github.ref, 'refs/tags/')`, so the
  `tags:` filter is load-bearing and a `main` push builds and scans without publishing —
  confirmed at `action.yml:200-204`
  (spec: *a version tag is pushed*, *a branch push does not publish*)
- [x] 1.3 Confirm the tag scheme the action actually produces rather than assuming semver
  expansion: it forces `flavor: latest=false` and leaves `docker/metadata-action` at its
  `type=ref` default with no input to change either (`action.yml:93-99`), so `v0.1.0`
  publishes exactly `:v0.1.0` — no `latest`, no `0.1`. Verify by reading the action source at
  the pinned SHA, and record the consequence for consumers in the README
  (spec: *no moving tag is published*)
- [x] 1.4 Set `concurrency: docker-${{ github.ref }}` with `cancel-in-progress: false`, and
  comment why: a superseded run may be mid-push to ghcr. Verify no expression remains that
  would evaluate against a `pull_request` event, now that the trigger is gone

## 2. Multi-architecture publishing

- [x] 2.1 Resolve the action version that carries a `platforms` input. Verify the release tag
  → SHA mapping through the API rather than trusting a comment:
  `gh api repos/schubergphilis/mcvs-docker-action/git/ref/tags/v0.11.8-rc.1` returns
  `3323a5f9234b86b1faf3e6d43cca6d4ff984da47`, and that tag is the first containing
  `0067477 feat: build and scan linux/arm64 images (Closes #31)`
  (spec: *the published image covers every architecture the build supports*)
- [x] 2.2 Repin from `006747742805f19e0f5a97eeeeed8cac6cf45130 # v0.11.6` to
  `3323a5f9234b86b1faf3e6d43cca6d4ff984da47 # v0.11.8-rc.1`. The old pin was a loose commit on
  the action's default branch carrying a version comment that resolved to a different SHA
  (`v0.11.6` is `1de6c6ce1dd24cdea3b1964a13ac902a7cd57128`) — the two zizmor code-scanning
  alerts on `docker.yml:44`. Verify both the SHA and the comment resolve to the same release
  (spec: *a version comment that does not match its pin is rejected*,
  *a mutable reference is rejected*)
- [x] 2.3 Pass `platforms: linux/amd64,linux/arm64` explicitly rather than inheriting the
  action's identical default, and comment why: this is an rc pin whose default may move before
  GA, and this value names what gets published. Verify the input exists at the pinned SHA and
  is spelled as the action declares it — GitHub Actions silently ignores an unknown `with:`
  key, so a misspelling would publish the default with nothing reporting it
  (spec: *the published architecture set is explicit*)
- [x] 2.4 Remove the `docker/setup-buildx-action` prohibition comment, which no longer
  describes the action: it now sets up QEMU and buildx itself (`action.yml:70-73`) and pushes
  the manifest list with buildx rather than `docker push`. Replace it with the reason a setup
  step must still not be added here — it would replace the builder whose layer cache the
  action's build and push steps share (`action.yml:66-68`, `191-195`)
- [x] 2.5 Record in the workflow comment that only one platform is scanned: the action loads a
  single image into the docker store and prefers `linux/amd64` (`action.yml:74-89`), so
  dockle, dive and grype cover amd64 while arm64 is published unscanned. Verify by reading the
  action's scan steps that they all target the single `mcvs-docker-action:scan` tag built at
  `steps.platform.outputs.scan_platform`
  (spec: *an architecture is published without being scanned*)
- [ ] 2.6 Confirm on a real run that the manifest list carries both architectures:
  `docker buildx imagetools inspect ghcr.io/schubergphilis/claude-docker:<tag>` lists
  `linux/amd64` and `linux/arm64` and no `unknown/unknown` entry (the action sets
  `provenance: false` for exactly that reason). Blocked until §5's first tag is pushed — no
  docker daemon in the authoring environment, and nothing is published yet
  (spec: *pulling on a covered architecture*)

## 3. Scanner suppression records

- [x] 3.1 Add `.grype.yaml` with three rules, each scoped by package type or location and
  carrying a `reason`, and a header stating why the file is load-bearing: the action hardcodes
  `severity-cutoff: high`, `fail-build: true` and `only-fixed: false` with no input to relax
  any of them (`action.yml:156-163`), and the scan runs before the push. Verify no rule is
  scoped by CVE ID
  (spec: *accepted scanner findings are recorded and scoped*)
- [x] 3.2 Scope the `go-module` rule to `location: /usr/bin/**` so it covers the vendored code
  inside the prebuilt `gh`, `glab` and `task` binaries but NOT the Go toolchain this repo pins
  itself at `/usr/local/go` — a stdlib CVE there is fixable by bumping `ARG GO_VERSION` and
  must stay enforced. Verify by confirming the toolchain's install path in the Dockerfile is
  outside the glob
  (spec: *a suppression does not cover a fixable instance*)
- [x] 3.3 Scope the npm rule by location (`**/node_modules/npm/**`) rather than by package
  name. Verify the four remaining findings (`brace-expansion`, `ip-address`, `tar`, `undici`)
  are genuinely unfixable from `pins/` before accepting them: `@anthropic-ai/claude-code` and
  `pnpm` both declare zero dependencies and ship bundled, all four are vendored inside the npm
  the NodeSource deb carries, and no released Node clears the set — 24.20.0 fixes two and
  still ships `ip-address@10.2.0` and `tar@7.5.19`. Confirm the glob matches npm's tree at any
  prefix and not the globals beside it, against `bmatcuk/doublestar` v2, the matcher grype
  uses
  (spec: *an unrelated vulnerable package stays enforced*)
- [x] 3.4 Add `.dockleignore` with only the checkpoints that can gate at the action's
  `exit-level: warn` — `CIS-DI-0001` (no `USER`, by design) and `DKL-DI-0005` (the `glab`
  layer installs a local `.deb` and never populates `/var/lib/apt/lists`). Verify
  `CIS-DI-0008` and `DKL-LI-0003` report as INFO and are therefore left visible rather than
  suppressed, and that the action already ignores `CIS-DI-0005`/`CIS-DI-0006` itself
  (`action.yml:143-148`) so neither needs an entry here
- [x] 3.5 Enumerate `dockle-accept-key` exhaustively rather than guessing: the action passes
  an empty sensitive-word, which makes dockle's `CIS-DI-0010` regex end in an `.*`
  alternative, so every `NAME=value` token in layer history is FATAL. Verify the list against
  the keys dockle reports one-per-line per run — the base image's own rockcraft/umoci tokens
  plus this Dockerfile's — and drop entries that cannot occur

## 4. PR-path cost

- [x] 4.1 Drop the `pull_request` trigger. `ci.yml`'s `Docker build (validate, no push)`
  already builds on every PR with a `type=gha` layer cache this action does not use, and now
  builds one architecture where this builds two, the second emulated. Verify the measured gap
  on this PR's own checks — 1m10s cached against 3m0s/4m6s uncached — and that `ci.yml`'s job
  is unchanged by this change
  (spec: *an unrelated pull request*)
- [x] 4.2 Keep `workflow_dispatch` as the pre-merge escape hatch and say so in the workflow
  comment, since dropping the PR trigger means a `.grype.yaml`, `.dockleignore` or
  scanner-visible Dockerfile change is not validated by this job until it lands on `main`
  (spec: *validating a scanner-configuration change before merge*)
- [x] 4.3 Leave this job out of `main`'s ruleset and comment that it should stay out: with
  `only-fixed: false` at a `high` cutoff an unrelated upstream CVE turns it red. Verify the
  ruleset still requires exactly `Validate` and `Docker build (validate, no push)`, and that
  renaming the job does not disturb either context
  (spec: *an unfixed upstream vulnerability*)

## 5. Docs

- [x] 5.1 Add a README section documenting GHCR as an install path: the pull reference, that
  consumers pin the full `v`-prefixed tag because no `latest` is published, the architectures
  published, and `CLAUDE_DOCKER_IMAGE` as the existing way to point the wrapper at it. Verify
  the building-locally path is still presented first and still supported, and that `run.sh`'s
  `claude-code:local` default is unchanged
  (spec: *a new user chooses an install path*, *pointing the wrapper at the published image*)
- [x] 5.2 State in that section that dockle, dive and grype cover `linux/amd64` only, so
  `linux/arm64` is published without passing them. Verify the same fact is recorded in the
  workflow comment, so the two cannot drift
  (spec: *an architecture is published without being scanned*)
- [x] 5.3 State that the scan runs before the push, so a failing run on a `v*` tag publishes
  nothing — a tag existing in the repository with no package behind it is otherwise a
  confusing failure to diagnose
  (spec: *the failure mode is documented*)
- [ ] 5.4 After the first release, confirm the documented pull command works verbatim against
  the public package on both architectures. Blocked until 6.1-6.2

## 6. Release (operator)

- [ ] 6.1 Push the first `v*` tag from a `main` commit whose Docker run is green, and confirm
  the push step reports success rather than `skipped`
- [ ] 6.2 Flip the newly created GHCR package from private to public. GHCR creates a package
  private on first push and nothing in CI can change that
- [ ] 6.3 Close [#17](https://github.com/schubergphilis/claude-docker/pull/17) in favour of
  this change

## 7. Verification

- [x] 7.1 Run `actionlint .github/workflows/docker.yml` and confirm it passes. Note what this
  does and does not prove: it validates workflow syntax, expressions and `runs-on` labels, not
  that the action's `with:` keys exist — 2.3 covers that against the action source
- [x] 7.2 Record what cannot be verified in the authoring environment: there is no docker
  daemon and no grype, dockle or dive, so no claim about scan results, build success or
  manifest contents may be ticked from here. The measured figures quoted in `design.md` (105
  High/Critical before the rules; 0 remaining, 202 of 531 matches ignored across 1962
  packages) come from this branch's own CI runs, not from a local scan
- [x] 7.3 Verify every action SHA in the new workflow resolves to the release its comment
  names, through the API rather than by eye — `actions/checkout` v7.0.1 and
  `mcvs-docker-action` v0.11.8-rc.1. This is the check the previous pin failed
  (spec: *the publishing action is referenced immutably*)
- [x] 7.4 Run `openspec validate publish-image-to-ghcr --type change --strict
  --no-interactive` and confirm it passes
- [ ] 7.5 Confirm on the merged `main` run that the full pipeline is green end to end —
  hadolint at the action's stricter `style` threshold, build, dockle, dive, grype image scan,
  grype source scan — and that the push step reports `skipped` on a branch push. Blocked until
  merge; the PR no longer runs this workflow by design (4.1)
