# Tasks

## 1. Spec

- [x] 1.1 ADDED capability `host-container-engine`
- [x] 1.2 MODIFIED `external-cli-tools` *gh, glab, aws v2 installed*; `cli-help` *Help output enumerates every wrapper flag*; `multi-workspace-mounts` *Variadic workspace args*; `container-runtime` *The entrypoint writes the vouched-for workspaces to system git config*
- [x] 1.3 `openspec validate host-container-engine --strict` passes

## 2. Wrapper, entrypoint and image

- [x] 2.1 `run.sh`: `--docker` flag, help text and `CLAUDE_DOCKER_SOCKET`; refused with `--egress-lock`; `docker` in `CLAUDE_DOCKER_FLAGS`
- [x] 2.2 `run.sh` `build_docker_socket`: socket discovery order, not-a-socket and no-socket errors, Git Bash refusal, `/run/docker.sock` mount and `DOCKER_HOST`, `--userns=keep-id --user 0:0 --passwd=false` under rootless podman, `CLAUDE_DOCKER_PROJECT_ALIAS`
- [x] 2.3 `run.sh` `build_workspace_mounts` / `check_mirror_path` / `stage_git_overlays`: workspaces and their `.git/config` overlay at the host path; system directories refused
- [x] 2.4 `run.sh` `stage_docker_tmp`: `$stage/tmp` mounted at its own path as `TMPDIR`; agent container labelled `claude-docker.docker=<sid>`
- [x] 2.5 `run.sh` `docker_snapshot` / `docker_cleanup`: before/after diff, `claude-*` exclusions, the other-session guard, one-line notices; EXIT trap retries the stage removal with `podman unshare`
- [x] 2.6 `entrypoint.sh`: `alias_project` (host-path key linked to the `/workspaces` one, existing sessions merged), `join_socket_group` (socket GID as supplementary group), `trust_workspaces` accepts host paths when `CLAUDE_DOCKER_FLAGS` lists `docker`
- [x] 2.7 Dockerfile: Docker CLI, compose and buildx plugins from Docker's apt repository

## 3. Docs

- [x] 3.1 `docs/usage.md` *Host container engine (`--docker`)*: socket order, permissions, host-path workspaces and `TMPDIR`, session cleanup, Git Bash
- [x] 3.2 `docs/security.md`: threat-model bullet, the `--egress-lock` refusal
- [x] 3.3 `docs/auth.md` flag table, `docs/vision-and-scope.md` options row

## 4. Verification

- [x] 4.1 BATS `run.bats`: `validate_opts`, `build_workspace_mounts`, `check_mirror_path`, `build_docker_socket`, `stage_git_overlays`, `stage_docker_tmp`, `docker_snapshot` / `docker_cleanup`, `create_stage` unshare fallback, `run_container` `RUN_OPTS`, `main` end to end
- [x] 4.2 BATS `entrypoint.bats`: `alias_project`, `join_socket_group`, `trust_workspaces` under `--docker`
- [x] 4.3 Verified by hand on a WSL2 rootless-podman host: `docker build` / `docker run -v "$PWD:..."` from a `--docker` session, two concurrent sessions, cleanup of a stage dir holding subordinate-UID files
- [ ] 4.4 Verified by hand on a rootful Docker host (socket group join) and on macOS Docker Desktop
