## 1. Spec

- [x] 1.1 MODIFIED *Credentials opt-in* in `specs/external-cli-tools/spec.md`: `--glab`
  discovery and `GITLAB_HOST` forwarding, three scenarios
- [x] 1.2 `openspec validate discover-glab-token --strict` passes

## 2. Wrapper

- [x] 2.1 Add `GITLAB_HOST` to the `--glab` `ENV_VARS` list
- [x] 2.2 When `GITLAB_TOKEN` is unset after `op://` resolution, discover it with
  `glab config get token --host <default host>`; silent skip; forward by bare name
- [x] 2.3 `--glab` usage text

## 3. Docs

- [x] 3.1 README § *Credential opt-in* `--glab` row
- [x] 3.2 `docs/auth.md` § *GitLab token discovery*

## 4. Verification

- [x] 4.1 `tests/test_op_references.py`: stub glab token for the `GITLAB_HOST` host is
  forwarded by name and absent from argv; an explicit `op://` value is not replaced
- [x] 4.2 `bash -n run.sh`; shellcheck runs in CI
