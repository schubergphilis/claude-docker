## 1. Spec

- [x] 1.1 MODIFIED *The image is published on a version tag*: a published draft's tag starts the pipeline; no dispatch
- [x] 1.2 MODIFIED *Publication is gated on the lint and scan stages*: a tag with no pipeline run, without the dispatch cause
- [x] 1.3 ADDED *Releases are drafted, and published by a maintainer*
- [x] 1.4 `openspec validate draft-releases --strict` passes

## 2. Workflows

- [x] 2.1 `.github/actions/draft-release/action.yml`: composite action that drafts the next release
- [x] 2.2 `release.yml`: run the action on push to `main` and on dispatch (with `dry_run`); drop auto-release and the `docker.yml` dispatch
- [x] 2.3 `ci.yml`: run `tests/draft-release/run_tests.sh` in Validate

## 3. Docs

- [x] 3.1 `docs/maintenance.md`: how a release is drafted and published, and how to choose a different version
- [x] 3.2 `docs/installation.md`: a tag with no Docker run means the pipeline didn't start for it, recovered with `gh workflow run docker.yml --ref <tag>`

## 4. Verification

- [x] 4.1 `tests/draft-release/run_tests.sh` passes locally
- [ ] 4.2 After merge: the first `release.yml` run on `main` creates a draft with the expected next version
- [ ] 4.3 First publish: the tag starts `docker.yml` and the image is published
