## 1. Spec

- [x] 1.1 Add *Secret-manager references in forwarded credentials* to
  `specs/external-cli-tools/spec.md`
- [x] 1.2 `openspec validate resolve-op-references --strict` passes

## 2. Wrapper

- [x] 2.1 Add `resolve_op_ref` to `run.sh` and call it from the shared `ENV_VARS` forward
  loop and the `UV_INDEX_*` credential scan
- [x] 2.2 Resolve `GH_TOKEN` / `GITHUB_TOKEN` under `--gh` before sidecar token discovery
  (`--gh-direct` already routes them through the forward loop)
- [x] 2.3 Exit 1 when `op` is missing or `op read` fails; name only the variable and drop
  `op`'s stderr, which echoes the reference path

## 3. Docs

- [x] 3.1 README § *Credential opt-in*: `op://` syntax, host-only resolution,
  `OP_SERVICE_ACCOUNT_TOKEN` as the unattended path

## 4. Verification

- [x] 4.1 `tests/test_op_references.py` drives `run.sh` with stub `docker` and `op`:
  resolved value forwarded by name and absent from argv, plain value untouched, missing
  `op` and failed read both exit 1 without launching or leaking the reference
- [x] 4.2 `bash -n run.sh`; shellcheck runs in CI
