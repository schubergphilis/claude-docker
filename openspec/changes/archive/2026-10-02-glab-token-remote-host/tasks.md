## 1. Spec

- [x] 1.1 MODIFIED *Credentials opt-in*: remote-host candidate, warning on no token
- [x] 1.2 `openspec validate glab-token-remote-host --strict` passes

## 2. Wrapper

- [x] 2.1 Candidate hosts: `GITLAB_HOST`, else first workspace's origin host, then glab's default host
- [x] 2.2 stderr warning when no token is found
- [x] 2.3 `--glab` usage text

## 3. Docs

- [x] 3.1 README § *Credential opt-in* `--glab` row and `docs/auth.md` § *GitLab token discovery*

## 4. Verification

- [x] 4.1 `tests/test_glab_token.py`: remote host discovered with `GITLAB_HOST` unset; warning on no token
- [x] 4.2 `bash -n run.sh`; shellcheck
