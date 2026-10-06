## 1. Spec

- [x] 1.1 MODIFIED *Credentials opt-in*: port handling, dedupe, unresolved common dir, port scenario
- [x] 1.2 `openspec validate glab-discovery-followups --strict` passes

## 2. Wrapper

- [x] 2.1 Keep the port except for `ssh://` and scp-style remotes
- [x] 2.2 Strip the path before the user info
- [x] 2.3 Skip hosts already tried
- [x] 2.4 No `/config` fallback when `rev-parse --git-common-dir` fails

## 3. Docs

- [x] 3.1 `docs/auth.md` § *GitLab token discovery*

## 4. Verification

- [x] 4.1 Tests: ports, parse order, duplicate host, symlinked `.git` / `config`, unresolvable pointer
- [x] 4.2 shellcheck; full unittest suite
