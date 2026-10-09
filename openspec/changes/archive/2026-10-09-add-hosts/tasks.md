## 1. Spec

- [x] 1.1 ADDED *Static host entries for networks without DNS*; MODIFIED help requirement
- [x] 1.2 `openspec validate add-hosts --strict` passes

## 2. Wrapper

- [x] 2.1 `validate_opts`: parse and validate `CLAUDE_DOCKER_ADD_HOSTS`
- [x] 2.2 `start_gh_sidecar`: pass the entries to the sidecar
- [x] 2.3 `build_host_args`: pass the entries to the agent, skipping the sidecar's three hosts under `--gh`
- [x] 2.4 Help text, Environment section

## 3. Docs

- [x] 3.1 `docs/usage.md`

## 4. Verification

- [x] 4.1 BATS: validation, agent wiring, sidecar wiring, `--gh` skip
- [x] 4.2 shellcheck and the full BATS suite
