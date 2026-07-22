## Why

`run.sh` hardcodes `docker run`, so the wrapper only starts a container where a
`docker` binary is on PATH. On podman-only hosts — the default on Windows
(`podman machine` + WSL backend) and a common drop-in on Linux — `claude-docker`
fails immediately with `docker: command not found`, even though a fully
functional, CLI-compatible engine is installed.

There is a second, Windows-specific failure. From Git Bash (MSYS/MINGW) the
shell's automatic POSIX→Windows path-translation layer rewrites the
container-side Unix paths in the engine's argv (`/workspaces/<name>`, the `-w`
value, `--add-dir` values, `/root/...`, `/run/...`) into Windows paths before
the native `podman.exe` / `docker.exe` ever sees them, producing:

```
Error: invalid option type "\Program Files\Git\workspaces\claude-shared"
```

Both failures were reproduced and fixed on a real Windows host (Git Bash,
podman 5.8.2, WSL backend).

## What Changes

- **Select the container runtime instead of hardcoding `docker`.** Two tiers,
  zero new installed command name:
  1. `CLAUDE_DOCKER_RUNTIME` — explicit override, allowlisted to `docker` or
     `podman`. This is the canonical, everywhere-it-works way to force an
     engine: scripts, CI, editor integrations, and non-interactive shells all
     honour it.
  2. **docker-first auto-detect** when the override is unset — prefer `docker`,
     fall back to `podman`, error with an install hint when neither is present.
     This is what fixes the podman-only host zero-config.
- **Allowlist the override** to `docker`/`podman` before it reaches the
  container-runtime invocation, so an arbitrary on-PATH binary named in
  `CLAUDE_DOCKER_RUNTIME` can never be run with the full `run …` argv.
- **Run the selection after wrapper-flag parsing**, so `-h`/`--help` still
  short-circuits to exit 0 on a host with no engine installed, and a real run
  on an engine-less host still fails before any `mktemp`/`cp` staging.
- **Fix MSYS/MINGW argv path translation.** Under Git Bash and other
  MSYS/Cygwin shells, disable the shell's automatic argv path conversion and
  translate host bind-mount *sources* to native Windows form ourselves (via
  `cygpath`), so container-side paths reach the engine verbatim while host
  paths still resolve.
- **Document runtime selection in `--help` and the README.** The README
  presents `CLAUDE_DOCKER_RUNTIME=podman` as the mechanism and an optional
  shell alias as sugar — explicitly *not* as a PATH-binary replacement, since
  an alias only resolves at an interactive prompt.

Out of scope (deliberately): a second installed command name (e.g.
`claude-podman`). An earlier draft dispatched on `argv[0]` to provide one; it is
dropped in favour of the env-var override so the project carries a single
command. Also out of scope: nerdctl / other CLI-compatible engines (the
allowlist can be widened later if a real need appears), and rewriting the
wrapper to be POSIX `sh` rather than bash.

## Capabilities

### New Capabilities

- `container-runtime`: how `run.sh` chooses which container engine to invoke
  (`CLAUDE_DOCKER_RUNTIME` override + docker-first auto-detect), and how it
  keeps container-side paths intact under MSYS/MINGW shells on Windows.

### Modified Capabilities

None. The `cli-help` behaviour is unchanged: the runtime selection runs *after*
the `--help` short-circuit, so `claude-docker --help` still exits 0 with no
engine on PATH.

## Impact

- **Code**: `run.sh` — add the runtime-selection block after the argument-parse
  loop; add MSYS detection, argv-conversion disabling, and a centralized
  `hostpath()` helper applied to every host bind-mount source; parameterize the
  final `docker run` line to `"$RUNTIME" run`. Add a `CLAUDE_DOCKER_RUNTIME`
  row to the `print_help` heredoc.
- **Docs**: `README.md` — a short "Container runtime" section covering
  auto-detect, the env-var override, the optional alias, and podman-on-Windows.
- **Specs**: new `container-runtime` capability.
- **No breaking changes**: on a docker host with no `CLAUDE_DOCKER_RUNTIME` set
  and a non-MSYS shell, behaviour is byte-for-byte identical to today
  (`hostpath()` is the identity function off-MSYS, auto-detect resolves to
  `docker`).
- **Dependencies**: none added. `cygpath` is already present in every MSYS/Git
  Bash environment; it is only invoked when running under one.
