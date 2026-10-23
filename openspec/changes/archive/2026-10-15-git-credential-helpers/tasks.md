## 1. Spec

- [x] 1.1 ADDED *Git credential helper per forge host*; MODIFIED *Windows hosts get a working in-container identity and git*
- [x] 1.2 `openspec validate git-credential-helpers --strict` passes

## 2. Wrapper

- [x] 2.1 `build_git_config`: one host-scoped credential helper per forge flag, one `GIT_CONFIG_*` list shared with `safe.directory`

## 3. Docs

- [x] 3.1 `docs/auth.md`: *Git over HTTPS* and *SSH remotes*

## 4. Verification

- [x] 4.1 bats: no forge flag adds nothing; one helper per forge host; the PAT helper answers for its host and not for another
- [x] 4.2 Full bats and unittest suites
