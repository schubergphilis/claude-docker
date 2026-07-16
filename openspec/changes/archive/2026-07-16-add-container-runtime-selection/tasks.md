## 1. Runtime selection in run.sh

- [x] 1.1 After the argument-parse `for` loop, add the runtime-selection block: read `RUNTIME="${CLAUDE_DOCKER_RUNTIME:-}"`, allowlist it with `case "$RUNTIME" in ""|docker|podman) ;; *) error+exit ;; esac`, then auto-detect docker-first when empty, or verify the requested runtime is on PATH otherwise (`run.sh` around the `RUNTIME=` block).
- [x] 1.2 Placement confirmed after the `--help` short-circuit and before the first `mktemp`/`cp` staging (verified: TEST 4 `--help` exits 0 with no engine; TEST 3 real run errors before any `host.*` staging dir is created).
- [x] 1.3 Parameterized the final invocation `docker run …` → `"$RUNTIME" run …`; kept it as a child process (no `exec`) so the `EXIT` trap still cleans the staging dir (verified: TEST 3 shows staging count before==after).
- [x] 1.4 Added a `CLAUDE_DOCKER_RUNTIME` row to the `print_help` `Environment:` section (values `docker`/`podman`, default auto-detect docker-first).

## 2. MSYS/MINGW path handling in run.sh

- [x] 2.1 Added MSYS detection (`uname -s` → `MINGW*`/`MSYS*`/`CYGWIN*` sets `IS_MSYS=1`) and, under MSYS, `export MSYS2_ARG_CONV_EXCL='*'` + `export MSYS_NO_PATHCONV=1`.
- [x] 2.2 Added `hostpath()`: `cygpath -m "$1"` under MSYS-with-cygpath, else `printf '%s' "$1"` (identity). Defined before the first bind mount (verified off-MSYS identity: TEST 1 workspace `-v` source is the plain POSIX path).
- [x] 2.3 Wrapped every host bind-mount source in `hostpath()` — workspace, git-config overlay, host-config staging (`$stage/*`, `$CLAUDE_CONFIG_DIR/*`), statusline, settings seed, and each credential source (`$glab_src`, `$HOME/.aws/*`, `$HOME/.terraform.d/*`, `$npmrc_src`, `uv.toml`, `$pip_conf`). Container targets / `-w` / `--add-dir` / `--tmpfs` / named volumes left literal.

## 3. Documentation

- [x] 3.1 Added a "Container runtime" section to `README.md`: docker-first auto-detect (podman-only zero-config), `CLAUDE_DOCKER_RUNTIME` as the canonical override, and the optional interactive-only alias caveat.
- [x] 3.2 Documented podman-on-Windows (Git Bash + `podman machine` WSL backend) and the MSYS path-handling behaviour; noted the build is the engine's own command (`podman build …`). No second install/symlink line added.

## 4. Verification (Linux-runnable)

- [x] 4.1 Stub `podman` on PATH + `CLAUDE_DOCKER_RUNTIME=podman ./run.sh <ws>` → stub invoked as `run …`, first arg `run`, and container-side paths intact (`/workspaces/ws` appears; `-w /workspaces/ws`). PASS.
- [x] 4.2 `CLAUDE_DOCKER_RUNTIME=bogus ./run.sh <ws>` → exit 1, `must be 'docker' or 'podman'` error, stub never invoked (0 bytes captured). PASS.
- [x] 4.3 PATH without docker/podman → `./run.sh --help` exits 0 with usage; a real run exits 1 with the no-engine error naming docker/podman/`CLAUDE_DOCKER_RUNTIME` and leaves no `host.*` staging dir. `CLAUDE_DOCKER_RUNTIME=podman` with podman absent → exit 1, `requested runtime 'podman' not found on PATH`. PASS.
- [x] 4.4 Off-MSYS argv unchanged: `hostpath()` returns input verbatim (TEST 1 workspace source is the plain POSIX path, no `cygpath` translation applied).

## 5. Windows validation (manual, real host)

- [x] 5.1 Validated on a real Windows host (Git Bash / MINGW64 + podman, WSL backend): `podman build -t claude-code:local .` succeeds; `podman run --rm claude-code:local claude --version` runs Claude Code; and the wrapper starts a container via podman with no `docker` binary present and no `invalid option type "\Program Files\Git\workspaces\..."` error — confirming both the docker-first auto-detect fallback and the MSYS argv path fix.

## 6. Validation

- [x] 6.1 `openspec validate add-container-runtime-selection --strict` exits 0.
- [x] 6.2 Re-ran `--strict` after the parallel-command requirement was dropped: the change adds only the `container-runtime` capability and modifies none, so no orphaned requirement remains.
- [x] 6.3 `--help` round-trips: `CLAUDE_DOCKER_RUNTIME` appears in the `Environment:` section with values `docker`/`podman`, matching the `""|docker|podman` allowlist in the selection block.
