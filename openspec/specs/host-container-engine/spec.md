# host-container-engine Specification

## Purpose

Lets a session drive the host's container engine (Docker or Podman) over its API socket with the `--docker` flag: what the socket is, who in the container may open it, why workspaces then keep their host paths, how a session's history carries across modes, and what the wrapper removes from the engine when the session ends so that nothing it created outlives it.

## Requirements

### Requirement: The host engine's socket is an opt-in

`run.sh` SHALL accept a `--docker` wrapper flag. With it, `run.sh` SHALL bind-mount the host container engine's API socket at `/run/docker.sock` in the agent container and set `DOCKER_HOST=unix:///run/docker.sock`, so the image's `docker` CLI (with the compose and buildx plugins) drives the host engine. No engine daemon SHALL run in the container. The bind source SHALL be a path the engine itself can see: on macOS, where the engine runs in a VM, `/var/run/docker.sock` for docker and the server-side path podman reports in `info` (`host.remoteSocket.path`) for podman, stopping with a message when podman reports none; the host-side socket stays what `run.sh` dials for its own listings. Without the flag, no socket SHALL be mounted and `DOCKER_HOST` SHALL NOT be set. `run.sh` SHALL list `docker` in `CLAUDE_DOCKER_FLAGS` when the flag is active.

The socket SHALL be, in order: `CLAUDE_DOCKER_SOCKET` when set; the host's `DOCKER_HOST` when it is a `unix://` URL; else the first that exists of the selected runtime's usual sockets — for podman `$XDG_RUNTIME_DIR/podman/podman.sock`, `/run/podman/podman.sock`, `/var/run/docker.sock`; for docker `/var/run/docker.sock` first. A configured path that is not a socket, or no socket found, SHALL make `run.sh` exit 1 before starting any container, with an error that names `systemctl --user enable --now podman.socket` for podman hosts.

#### Scenario: the socket reaches the container

- **GIVEN** a rootless podman host with its API socket enabled
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** `docker info` inside the session reports the host engine
- **AND** `docker ps` inside the session lists the session's own agent container

#### Scenario: a VM-backed engine on macOS

- **GIVEN** macOS with `DOCKER_HOST=unix:///Users/me/.colima/default/docker.sock`
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** the agent container mounts `/var/run/docker.sock`, not the path under `/Users`, and `run.sh` dials the `/Users` socket for its listings

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

Under rootless podman, decided by asking the engine behind the socket the session uses (not the default connection), `run.sh` SHALL start the agent container with `--userns=keep-id --user 0:0 --passwd=false`, so the entrypoint still starts as (namespaced) root and the `HOST_UID` it drops to is the host user, who owns the socket. The same mapping SHALL apply to every rootless-podman session, with or without `--docker` (decided by `podman info` on the default connection then): the persistent volumes are shared and chowned to `HOST_UID` at each start, so two mappings would flip ownership from under a running session. Under a rootful engine, the entrypoint SHALL add the socket's group (by GID, creating a `docker-host` group when none has it) as a supplementary group of the `claude` user before the privilege drop, unless it is already the user's primary group, it is GID 0, or the image already has a group under that GID that is not `docker` or `docker-host`: the root group and the image's other groups reach far beyond the socket, so those are never joined and the entrypoint warns. The privilege drop and capability set SHALL be unchanged.

#### Scenario: rootless podman

- **GIVEN** a rootless podman host
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** the agent process runs as the host UID inside a `keep-id` user namespace and `docker ps` succeeds

#### Scenario: a root-owned socket

- **GIVEN** a Docker host whose socket is `root:root`
- **WHEN** the user runs `claude-docker --docker ~/repo`
- **THEN** the `claude` user is not added to GID 0, and `docker` in the session fails on the socket's permissions rather than running with the root group
- **AND** a socket whose GID is the image's `shadow` group is likewise not joined, with a warning

#### Scenario: a regular session next to a --docker one

- **GIVEN** a rootless podman host and a running `claude-docker --docker ~/a` session
- **WHEN** the user starts a regular `claude-docker ~/b`
- **THEN** both run with the same user mapping, the first session keeps writing its history and settings, and neither crashes

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

Because Claude Code keys its project directory by working directory, a `--docker` session of a workspace would get a project separate from a regular session's. `run.sh` SHALL pass the first workspace's `/workspaces/<name>` path as `CLAUDE_DOCKER_PROJECT_ALIAS`, and the entrypoint SHALL link the host-path project key to the `/workspaces/<name>` key when the latter exists: sessions already stored under the host-path key are moved into it first without overwriting; when a file exists on both sides with different content (memory files have fixed names), nothing SHALL be deleted or linked and the entrypoint SHALL warn. Otherwise the host-path key becomes a symlink. Keys over 200 characters SHALL be left alone.

#### Scenario: both keys hold a memory file

- **GIVEN** a `--docker` session wrote `memory/MEMORY.md` under the host-path key before a regular session created the `/workspaces/<name>` key with its own `memory/MEMORY.md`
- **WHEN** the next `--docker` session starts
- **THEN** both files are still there, no link is made, and the entrypoint warns which file collided

#### Scenario: --resume sees both modes

- **GIVEN** a regular `claude-docker ~/repo` session was run before
- **WHEN** the user runs `claude-docker --docker ~/repo -- --resume`
- **THEN** the picker lists the regular session

### Requirement: What appears on the engine during the session is kept or removed, as chosen at start

Under `--docker`, `run.sh` SHALL record the IDs of the engine's containers, images, volumes and networks before the agent starts and, at exit, act on those that are new. Which action is settled at start: `--docker-keep` keeps, `--docker-clean` removes, both together are refused, and with neither the wrapper SHALL ask on the terminal (`[Y/n]`, default remove) once the socket is resolved, so no fatal start-up check follows the answer, saying that the diff also holds anything started on the engine by hand during the session; without a terminal it SHALL keep and say how to choose. The diff records no creator, so anything that appears on the engine while the session runs is in it, whichever client made it.

Keeping: at exit the wrapper SHALL list what is new, by name, on stderr, and print a command for the host shell that removes it (always addressed at the socket the session used, so another docker context or podman connection in that shell cannot redirect it), with a warning to check the names first. Nothing is removed.

Removing: at exit the wrapper SHALL remove what is new in this order: containers (forced, with their anonymous volumes), networks, volumes, images. It SHALL NOT remove the resources `run.sh` names for other sessions' sidecars (`claude-auth-*`, `claude-egress-*`, the `claude-docker-egress-proxy` image; no other `claude-` prefix is exempt) or containers carrying the `claude-docker.session` label (`run.sh` puts it on every agent container, `--docker` or not), or the wrapper's own `claude-code-root` and `claude-code-home` volumes and the agent image (a first session creates or pulls them after the snapshot), and SHALL remove nothing while another `--docker` session's agent container is running (recognised by the `claude-docker.docker` label `run.sh` puts on every `--docker` agent container) or when the engine cannot answer that query. It SHALL print one line to stderr naming what it removed, and one naming what it left and why when something is left: another session running, or the engine refused.

A listing that fails at start SHALL be fatal, since an empty snapshot would make everything on the engine look new at exit; a listing that fails at exit SHALL do nothing and say so.

#### Scenario: the question at start

- **GIVEN** `claude-docker --docker ~/repo` on a terminal
- **WHEN** the session starts
- **THEN** it asks whether what appears on the host engine during the session is removed at exit, default yes, and says that hand-started containers on the engine are in that list too
- **AND** `--docker-keep` or `--docker-clean` skips the question, and without a terminal the session keeps and says so

#### Scenario: kept resources are listed with a removal command

- **GIVEN** a `--docker` session that chose keep, and the agent ran `docker compose up -d` and pulled an image
- **WHEN** the session exits
- **THEN** the stack's containers, network and volumes and the pulled image are still on the host engine
- **AND** stderr names them and prints a `docker rm -fv ...; docker network rm ...; docker volume rm ...; docker image rm -f ...` line for the host shell, with the warning to check the names

#### Scenario: a compose stack does not outlive a session that chose remove

- **GIVEN** `claude-docker --docker-clean ~/repo` and the agent ran `docker compose up -d` and pulled an image
- **WHEN** the session exits
- **THEN** the stack's containers, network and volumes and the pulled image are gone from the host engine
- **AND** stderr names what was removed

#### Scenario: another session's resources are left alone

- **GIVEN** two `--docker-clean` sessions, A started first
- **WHEN** session A exits while B is still running
- **THEN** nothing is removed, and stderr says what was left and that another `--docker` session is running
- **AND** when B exits last, what both created since A started is removed

#### Scenario: something started by hand on the same engine during the session

- **GIVEN** a `--docker` session, and the user runs `docker run -d --name scratch ...` from another terminal against the same engine while it runs
- **WHEN** the session exits
- **THEN** `scratch` is in the list: named among what was kept, or removed with the session's own if remove was chosen

#### Scenario: an engine the runtime cannot list

- **GIVEN** `--docker` with `CLAUDE_DOCKER_RUNTIME=podman` and `CLAUDE_DOCKER_SOCKET` pointing at docker's socket
- **WHEN** the session starts
- **THEN** it exits 1 before the agent runs, saying the runtime cannot list the engine and naming `CLAUDE_DOCKER_SOCKET` and `CLAUDE_DOCKER_RUNTIME`

#### Scenario: a first session's persistent volumes survive

- **GIVEN** no `claude-code-root` or `claude-code-home` volume exists yet, and the user runs `claude-docker --docker-clean ~/repo`
- **WHEN** the session exits
- **THEN** both volumes, created by the agent's `run`, and the agent image are still there; only what the agent created is removed

#### Scenario: a concurrent regular session's sidecar is untouched

- **GIVEN** a `--docker-clean` session, and a `claude-docker --gh` session started after it
- **WHEN** the `--docker-clean` session exits
- **THEN** the `--gh` session's agent container, its `claude-auth-proxy-*` container and `claude-auth-*` network are still there

### Requirement: The stage directory is removed even with subordinate-UID files in it

At exit, when the stage directory cannot be removed as the host user and the runtime is podman, `run.sh` SHALL retry the removal with `podman unshare`, since a nested container that ran as a non-root UID leaves files in the shared `TMPDIR` owned by a subordinate UID. If the directory still survives, `run.sh` SHALL print one line naming it instead of one error per file.

#### Scenario: a nested build's files are cleaned up

- **GIVEN** a `--docker` session on rootless podman in which `docker run -v "$TMPDIR/x:/w" ... ` wrote files as a non-root container user
- **WHEN** the session exits
- **THEN** the stage directory under `~/.cache/claude-docker/` is gone and no `Permission denied` lines are printed

### Requirement: The host engine with the egress lock is a warned breakout

When `--docker` is given together with `--egress-lock`, `run.sh` SHALL print a warning before starting any container and continue: the lock bounds the agent process, while a container started through the host engine's socket, and the engine's own image pulls, run on the host's network outside the proxy and its allowlist. The warning SHALL say so and that the host engine's audit is not the wrapper's.

#### Scenario: warned together

- **WHEN** the user runs `claude-docker --docker --api --egress-lock ~/repo`
- **THEN** `run.sh` prints a WARNING naming the breakout and starts the session with the lock in place for the agent process
