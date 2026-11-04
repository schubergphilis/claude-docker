# Host container engine (`--docker`)

## Why

Agents routinely need a container engine: to build the project's image, bring up a `docker compose` stack, or run a test suite that uses Testcontainers. Inside claude-docker there is none, and there is no reasonable child-image route: a daemon in the container needs `--privileged`, which the hardening forbids, and a second engine on the host needs the host's socket anyway. Users work around it by running those steps on the host themselves, outside the session.

Handing the session the host engine's API socket is the standard answer (Docker-outside-of-Docker). It is also the one option that reaches outside the container, since whoever holds the socket can start a container that mounts the host's filesystem. So it is opt-in, documented in the threat model as removing the container boundary, and refused together with `--egress-lock`, which it would bypass.

## What Changes

- **`--docker`** (new wrapper flag): the host engine's API socket is bind-mounted at `/run/docker.sock` and `DOCKER_HOST` points at it. The image gains the Docker CLI with the compose and buildx plugins; no daemon runs in the container. The socket is `CLAUDE_DOCKER_SOCKET`, else a `unix://` `DOCKER_HOST` on the host, else the selected runtime's usual socket; none found is a startup error that names the podman fix.
- **The engine resolves `-v` sources on the host**, so under `--docker` each workspace is mounted at its own host path instead of `/workspaces/<name>`, and `TMPDIR` is a per-session host directory mounted at the same path. `docker run -v "$PWD:..."`, compose `./` volumes and `mktemp` bind mounts then work unchanged. Workspaces under the image's own directories (`/usr`, `/etc`, `/workspaces`, …) are refused.
- **Identity.** Under rootless podman the agent container runs with `--userns=keep-id`, so the dropped-to user is the host user and can open the host-user-owned socket. Under a rootful engine the entrypoint adds the socket's group to the `claude` user.
- **The entrypoint trusts the host-path workspaces for git** (`safe.directory`), as it trusts `/workspaces/<name>` paths today; the widening values stay refused.
- **History and memory carry over.** Claude Code keys its project by directory; the entrypoint links the host-path key to the `/workspaces/<name>` one, so `--resume` and memory are shared between a `--docker` session and a regular one.
- **One user mapping for every rootless-podman session.** `--userns=keep-id` is added to regular sessions as well as `--docker` ones, because the shared volumes are chowned to the session user at each start and two mappings flip ownership from under a running session.
- **What appears on the engine during the session is kept or removed, as chosen at start.** `--docker` asks (default remove), `--docker-keep` / `--docker-clean` answer on the command line, no terminal means keep. Both act on a before/after diff of IDs, which also holds anything started on the engine by hand meanwhile: keeping lists it by name with a removal command for the host shell; removing never touches another claude-docker session's `claude-*` resources, and nothing at all while another `--docker` session is still running. Under rootless podman the stage directory is removed through `podman unshare`, since nested containers leave files owned by subordinate UIDs in the shared `TMPDIR`.
- Not supported from Git Bash (Docker Desktop on Windows exposes a named pipe). Refused with `--egress-lock`.

## Capabilities

### New Capabilities

- `host-container-engine`: the socket mount and its discovery, the host-path workspace and `TMPDIR` mirroring, identity under rootless and rootful engines, the project alias, session cleanup, and the `--egress-lock` and Git Bash refusals.

### Modified Capabilities

- `external-cli-tools`: *gh, glab, aws v2 installed* gains the Docker CLI with the compose and buildx plugins.
- `cli-help`: *Help output enumerates every wrapper flag* gains `--docker` and `CLAUDE_DOCKER_SOCKET`.
- `multi-workspace-mounts`: *Variadic workspace args*: under `--docker` the mount target is the workspace's host path.
- `container-runtime`: *The entrypoint writes the vouched-for workspaces to system git config*: under `--docker` a vouched-for host path is accepted too.

## Non-goals

- A daemon inside the container (docker-in-docker) or a per-session engine with its own storage. Images live in the host engine's storage; a session starts from what the engine has and leaves it as it found it.
- Attributing engine resources to the session that created them. The engine records no creator, so the exit step is a diff of IDs with the guards above, which is why it asks first and names everything; a session that is killed outright runs no exit step.
- Git Bash on Windows. WSL is the supported route.

## Impact

- `run.sh`: flag parsing and help, the `--egress-lock` conflict, `check_mirror_path` and the host-path mounts, `build_docker_socket` (socket discovery, keep-id), `stage_docker_tmp`, `docker_snapshot` / `docker_cleanup` and the EXIT trap's `podman unshare` fallback.
- `entrypoint.sh`: `alias_project`, `join_socket_group`, `trust_workspaces` accepts host paths under `--docker`.
- `Dockerfile`: `docker-ce-cli`, `docker-compose-plugin`, `docker-buildx-plugin` from Docker's signed apt repository, floating like `gh`.
- Docs: `docs/usage.md` (new section), `docs/security.md` (threat-model bullet), `docs/auth.md` (flag table), `docs/vision-and-scope.md` (options row), help text.
- Tests: `tests/bats/run.bats` and `tests/bats/entrypoint.bats`.
