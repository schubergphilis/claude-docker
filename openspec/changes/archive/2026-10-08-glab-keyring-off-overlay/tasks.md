## 1. Spec

- [x] 1.1 MODIFIED *Credentials opt-in*: `config.yml` overlay with the keyring off, new scenario
- [x] 1.2 `openspec validate glab-keyring-off-overlay --strict` passes

## 2. Wrapper

- [x] 2.1 `stage_glab_config`: copy `config.yml` with `use_keyring: false` into the stage dir and mount it read-only

## 3. Docs

- [x] 3.1 `docs/auth.md` § *GitLab token discovery*

## 4. Verification

- [x] 4.1 Tests: overlay turns the keyring off and keeps other keys; no overlay without a host `config.yml`
- [x] 4.2 Full unittest suite
