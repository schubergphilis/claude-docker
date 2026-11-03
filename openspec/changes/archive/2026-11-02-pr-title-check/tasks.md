## 1. Spec

- [x] 1.1 ADDED *Pull request titles are Conventional Commits*
- [x] 1.2 `openspec validate pr-title-check --strict` passes

## 2. Workflows

- [x] 2.1 `.github/actions/validate-pr-title/action.yml`: composite action that checks a title against Conventional Commits
- [x] 2.2 `pr-title.yml`: run the action on `opened`, `edited`, `reopened` and `synchronize`
- [x] 2.3 `ci.yml`: run `tests/validate-pr-title/run_tests.sh` in Validate

## 3. Docs

- [x] 3.1 `CONTRIBUTING.md`: the PR title is a Conventional Commit, because the draft release is counted from it
- [x] 3.2 `docs/maintenance.md`: the title check guards what the draft release reads

## 4. Verification

- [x] 4.1 `tests/validate-pr-title/run_tests.sh` passes locally
- [ ] 4.2 The check runs and passes on this pull request
- [ ] 4.3 After merge: a maintainer adds the check to the required status checks on `main`
