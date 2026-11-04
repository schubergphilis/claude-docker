# host-container-engine Specification

## Purpose
TBD - created by archiving change host-container-engine. Update Purpose after archive.

## Requirements

### Requirement: The host engine's socket is an opt-in

`run.sh` SHALL accept a `--docker` wrapper flag. With it, `run.sh` SHALL bind-mount the host container engine's API socket at `/run/docker.sock` in the agent container and set `DOCKER_HOST=unix:///run/docker.sock`, so the image's `docker` CLI (with the compose and buildx plugins) drives the host engine. No engine daemon SHALL run in the container. Without the flag, no socket SHALL be mounted and `DOCKER_HOST` SHALL NOT be set. `run.sh` SHALL list `docker` in `CLAUDE_DOCKER_FLAGS` when the flag is active.

The socket SHALL be, in order: `CLAUDE_DOCKER_SOCKET` when set; the host's `DOCKER_HOST` when it is a `unix://` URL; else the first that exists of the selected runtime's usual sockets — for podman `$XDG_RUNTIME_DIR/podman/podman.sock`, `/run/podman/podman.sock`, `/var/run/docker.sock`; for docker `/var/run/docker.sock` first. A configured path that is not a socket, or no socket found, SHALL make `run.sh` exit 1 before starting any container, with an error that names `systemctl --user enable --now podman.socket` for podman hosts.

#### Scenario: the socket reaches the container

- **GIVEN** a rootless podman host with its API socket enabled
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** `docker info` inside the session reports the host engine
- **AND** `docker ps` inside the session lists the session's own agent container

#### Scenario: no socket is a startup error

- **GIVEN** a podman host whose API socket is off and no `CLAUDE_DOCKER_SOCKET`
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** `run.sh` exits 1 naming the sockets it tried and `systemctl --user enable --now podman.socket`
- **AND** no container is started

#### Scenario: CLAUDE_DOCKER_SOCKET wins

- **GIVEN** `CLAUDE_DOCKER_SOCKET=/srv/engine.sock` (a socket) and `DOCKER_HOST=unix:///var/run/docker.sock`
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** `/srv/engine.sock` is mounted at `/run/docker.sock`

#### Scenario: without the flag nothing is mounted

- **WHEN** the user runs `claude-docker ~/repo`
- **THEN** `/run/docker.sock` does not exist in the container and `DOCKER_HOST` is unset

### Requirement: The dropped-to user can open the socket

Under rootless podman, `run.sh` SHALL start the agent container with `--userns=keep-id --user 0:0 --passwd=false`, so the entrypoint still starts as (namespaced) root and the `HOST_UID` it drops to is the host user, who owns the socket. Under a rootful engine, the entrypoint SHALL add the socket's group (by GID, creating a `docker-host` group when none has it) as a supplementary group of the `claude` user before the privilege drop, unless it is already the user's primary group. The privilege drop and capability set SHALL be unchanged.

#### Scenario: rootless podman

- **GIVEN** a rootless podman host
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** the agent process runs as the host UID inside a `keep-id` user namespace and `docker ps` succeeds

#### Scenario: rootful docker

- **GIVEN** a Docker host whose socket is `root:docker` mode `0660`
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** the agent process has the `docker` group's GID in its supplementary groups and `docker ps` succeeds

### Requirement: Workspaces and TMPDIR keep their host path

Under `--docker`, `run.sh` SHALL mount each workspace at its own host path instead of `/workspaces/<name>`, start the session in the first workspace's host path, pass the other workspaces' host paths as `--add-dir`, and mount the container-only `.git/config` overlay at the host path too. A workspace whose host path contains `:` or lies under a directory the image owns (`/bin`, `/boot`, `/dev`, `/etc`, `/lib*`, `/opt`, `/proc`, `/root`, `/run`, `/sbin`, `/sys`, `/usr`, `/var`, `/workspaces`) SHALL make `run.sh` exit 1 before starting any container. `run.sh` SHALL create a `tmp` directory in the session's stage directory, mount it at the same path, and set `TMPDIR` to it; it SHALL be removed with the stage directory at exit. `--docker` SHALL be refused from an MSYS/MINGW/Cygwin shell with an error that names WSL.

#### Scenario: a bind mount from the session resolves on the host

- **GIVEN** `claude-docker --docker ~/repo`
- **WHEN** the agent runs `docker run --rm -v "$PWD:/src" alpine ls /src` in the session
- **THEN** the listing shows `~/repo`'s contents

#### Scenario: mktemp paths can be bind-mounted

- **GIVEN** `claude-docker --docker ~/repo`
- **WHEN** the agent runs `f=$(mktemp) && docker run --rm -v "$f:/f" alpine test -f /f`
- **THEN** the command succeeds

#### Scenario: a workspace under a system directory is refused

- **WHEN** the user runs `claude-docker --docker /usr/local/src/repo`
- **THEN** `run.sh` exits 1 saying the workspace would shadow a container directory
- **AND** no container is started

### Requirement: Sessions share their history across modes

Because Claude Code keys its project directory by working directory, a `--docker` session of a workspace would get a project separate from a regular session's. `run.sh` SHALL pass the first workspace's `/workspaces/<name>` path as `CLAUDE_DOCKER_PROJECT_ALIAS`, and the entrypoint SHALL link the host-path project key to the `/workspaces/<name>` key when the latter exists: sessions already stored under the host-path key are moved into it first without overwriting, and the host-path key becomes a symlink. Keys over 200 characters SHALL be left alone.

#### Scenario: --resume sees both modes

- **GIVEN** a regular `claude-docker ~/repo` session was run before
- **WHEN** the user runs `claude-docker --docker ~/repo -- --resume`
- **THEN** the picker lists the regular session

### Requirement: What the session creates on the engine is removed at exit

Under `--docker`, `run.sh` SHALL record the IDs of the engine's containers, images, volumes and networks before the agent starts, and at exit remove those that are new, in this order: containers (forced, with their anonymous volumes), networks, volumes, images. It SHALL NOT remove resources whose name starts with `claude-` (other claude-docker sessions' sidecars, networks and the egress image), and SHALL remove nothing while another `--docker` session's agent container is running (recognised by the `claude-docker.docker` label `run.sh` puts on every `--docker` agent container). It SHALL print one line to stderr saying what it removed, and one saying what it left and why when something is left: another session running, or the engine refused.

#### Scenario: a compose stack does not outlive the session

- **GIVEN** `claude-docker --docker ~/repo` and the agent ran `docker compose up -d` and pulled an image
- **WHEN** the session exits
- **THEN** the stack's containers, network and volumes and the pulled image are gone from the host engine
- **AND** stderr says what was removed

#### Scenario: another session's resources are left alone

- **GIVEN** two `--docker` sessions, A started first
- **WHEN** session A exits while B is still running
- **THEN** nothing is removed, and stderr says what was left and that another `--docker` session is running
- **AND** when B exits last, what both created since A started is removed

#### Scenario: a concurrent regular session's sidecar is untouched

- **GIVEN** a `--docker` session, and a `claude-docker --gh` session started after it
- **WHEN** the `--docker` session exits
- **THEN** the `--gh` session's `claude-auth-proxy-*` container and `claude-auth-*` network are still there

### Requirement: The stage directory is removed even with subordinate-UID files in it

At exit, when the stage directory cannot be removed as the host user and the runtime is podman, `run.sh` SHALL retry the removal with `podman unshare`, since a nested container that ran as a non-root UID leaves files in the shared `TMPDIR` owned by a subordinate UID. If the directory still survives, `run.sh` SHALL print one line naming it instead of one error per file.

#### Scenario: a nested build's files are cleaned up

- **GIVEN** a `--docker` session on rootless podman in which `docker run -v "$TMPDIR/x:/w" ... ` wrote files as a non-root container user
- **WHEN** the session exits
- **THEN** the stage directory under `~/.cache/claude-docker/` is gone and no `Permission denied` lines are printed

### Requirement: The host engine does not combine with the egress lock

`run.sh` SHALL exit 1 before starting any container when `--docker` is given together with `--egress-lock`, since a container started through the host engine's socket is outside the egress proxy.

#### Scenario: refused together

- **WHEN** the user runs `claude-docker --docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 saying the two cannot be combined
- **AND** no container is started
