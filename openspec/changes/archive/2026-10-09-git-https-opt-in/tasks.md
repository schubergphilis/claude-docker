## 1. Spec

- [x] 1.1 ADDED *Git over HTTPS opt-in*; MODIFIED *Help output enumerates every wrapper flag*
- [x] 1.2 `openspec validate git-https-opt-in --strict` passes

## 2. Wrapper

- [x] 2.1 `--git-https` flag and help text
- [x] 2.2 `build_git_config`: insteadOf rewrites, credential helpers, `GLAB_GIT_PROTOCOL`, one `GIT_CONFIG_*` list shared with `safe.directory`

## 3. Docs

- [x] 3.1 README flag table, `docs/auth.md` SSH limitation

## 4. Verification

- [x] 4.1 bats: no flag adds nothing; per-forge config; real `git ls-remote --get-url` rewrite; flag alone warns
- [x] 4.2 Full bats and unittest suites
