## ADDED Requirements

### Requirement: Go environment exported by the image

The image SHALL export `GOROOT=/usr/local/go`, `GOPATH=/root/go`, and
`GOBIN=/root/go/bin` as `ENV`, so the values are present in the process
environment rather than existing only as `go env` defaults computed by the
toolchain. Scripts and non-Go tooling that read the variables directly SHALL
therefore agree with the toolchain.

The values SHALL be spelled against a literal `/root`, not `${HOME}`: Docker
does not define `HOME` during a build, so `"${HOME}/go"` expands to `/go`.
`/root` is the home directory on both paths through the entrypoint — the
legacy root fallback and the dropped-privilege user, whose passwd entry is
created with `-d /root`.

#### Scenario: the variables are set in a non-login shell

- **WHEN** a command runs in the container without a login shell — the
  entrypoint's `runuser -u`, a `docker exec`, or a plain `docker run` command
- **THEN** `GOROOT` is `/usr/local/go`, `GOPATH` is `/root/go`, and `GOBIN` is
  `/root/go/bin` in that process's environment

#### Scenario: the exported values match what the toolchain computes

- **WHEN** `go env GOROOT`, `go env GOPATH`, and `go env GOBIN` are compared
  against the exported `GOROOT`, `GOPATH`, and `GOBIN`
- **THEN** each pair agrees, so a script reading the variable and a script
  shelling out to `go env` reach the same directory

### Requirement: PATH ordering keeps volume-persisted directories non-shadowing

The default PATH SHALL place `/usr/local/go/bin` ahead of every system path,
and SHALL place both agent-writable directories that live in the persistent
`claude-code-root` volume — `/root/.local/bin` (the `pip install --user` /
`uv tool install` prefix) and `/root/go/bin` (the GOPATH `bin` directory, where
`go install` writes) — after every system path.

Both directories are writable by the agent and survive the session: `/root` is
a named volume shared across sessions and workspaces, and the image PATH
reaches the agent unchanged because the entrypoint execs `runuser -u` rather
than `runuser -l`. A binary one session leaves in either directory MUST NOT be
able to shadow a system binary (`git`, `gh`, `aws`, …) on a later run. They MAY
be on the default PATH for convenience, but only after every system path.

Neither directory is distinguishable from the other by anything the image can
check — same volume, same writer, same lifetime — so the usual convention that
a user-local prefix precedes the system paths SHALL NOT be applied to
`/root/.local/bin`. `/usr/local/go/bin` precedes the system paths so the
image's pinned toolchain wins over anything installed into the volume.

#### Scenario: a persisted GOPATH binary cannot shadow a system tool

- **GIVEN** a previous session left an executable named `git` in `/root/go/bin`
  in the persistent volume
- **WHEN** a new container starts and `git` is invoked
- **THEN** the system `git` runs, not the one from `/root/go/bin`

#### Scenario: a persisted user-prefix binary cannot shadow a system tool

- **GIVEN** a previous session left an executable named `gh` in
  `/root/.local/bin` in the persistent volume
- **WHEN** a new container starts, in any workspace, and `gh` is invoked
- **THEN** the system `gh` runs, not the one from `/root/.local/bin`

#### Scenario: go install output is runnable without an absolute path

- **WHEN** the user runs `go install <module>@<version>` and then invokes the
  installed command by name
- **THEN** the command resolves from `/root/go/bin` on PATH

#### Scenario: user-prefix installs are runnable without an absolute path

- **WHEN** the user installs a tool whose entry point lands in
  `/root/.local/bin` (for example `uv tool install` or `pip install --user`)
  and then invokes it by name
- **THEN** the command resolves from `/root/.local/bin` on PATH, provided no
  system binary of that name exists

#### Scenario: the smoke suite enforces the ordering

- **WHEN** `smoke/smoke.sh` runs against a built image
- **THEN** the in-container assertions confirm `/usr/local/go/bin` precedes
  `/usr/bin`, that `/usr/bin` precedes both `/root/.local/bin` and
  `/root/go/bin`, and that `git` resolves to `/usr/bin/git`
- **AND** they confirm the exported `GOROOT`, `GOPATH`, and `GOBIN` values

## REMOVED Requirements

### Requirement: PATH ordering keeps GOPATH binaries non-shadowing

Superseded by "PATH ordering keeps volume-persisted directories
non-shadowing" above. The guarantee is unchanged and strengthened; the title
and its single `/root/go/bin` scenario described only one of the two
agent-writable, volume-persisted directories now on the default PATH, so a
reader greping the title would conclude the requirement was about `go install`
output alone.
