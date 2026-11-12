## 1. Spec

- [x] 1.1 ADDED `multi-workspace-mounts` *Host path map on request*
- [x] 1.2 MODIFIED `cli-help` *Help output enumerates every wrapper flag*: `--host-paths`, `CLAUDE_DOCKER_HOST_PATHS`
- [x] 1.3 `openspec validate host-path-map --strict` passes

## 2. Wrapper

- [x] 2.1 `run.sh` `parse_args`: `--host-paths`; help text for the flag and `CLAUDE_DOCKER_HOST_PATHS`
- [x] 2.2 `run.sh` `build_host_path_prompt`: map each workspace to its host path (`cygpath -w` under Git Bash, read-only marked, a workspace whose host or container path has a control character left out with a one-line warning); merge the user's last `--append-system-prompt` (both spellings) after the map in one flag

## 3. Docs

- [x] 3.1 `docs/usage.md`: the flag, what it sends, the resume caveat, the merge with `--append-system-prompt`
- [x] 3.2 `docs/security.md`: what the map discloses, and that it grants nothing

## 4. Verification

- [x] 4.1 BATS: off by default; env and flag; read-only marked; control character in the host path and in the container path left out; user `--append-system-prompt` (both spellings, repeated) merged into one flag; `--append-system-prompt-file` untouched; trailing bare flag kept
- [x] 4.2 Manual: in a real session, one `--append-system-prompt` from the user and the map both reach the model
- [x] 4.3 shellcheck, `bats tests/bats`, unittest suite pass locally
