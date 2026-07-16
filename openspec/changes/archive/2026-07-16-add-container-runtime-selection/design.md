## Context

`run.sh` is a bash wrapper that assembles a long `docker run …` argv (workspace
bind-mounts, credential mounts, host-config staging, git-identity env, a
generated statusline wrapper) and launches a hardened container. Two
assumptions are baked in that break outside a Linux/macOS + Docker Desktop
world:

1. The engine binary is literally `docker`. Podman ships a docker-compatible
   CLI (`podman run …` accepts the same flags this wrapper uses) and is the
   default engine on Windows via `podman machine` (WSL backend) and a common
   Linux drop-in. On those hosts the wrapper dies at `docker: command not
   found` before doing anything.
2. The shell passes argv to the engine untouched. Under MSYS/MINGW (Git Bash on
   Windows), the runtime rewrites arguments that *look like* absolute POSIX
   paths into Windows paths before the native `docker.exe`/`podman.exe` sees
   them. Container-side paths (`/workspaces/<name>`, the `-w` value,
   `--add-dir` values, `/root/...`, `/run/...`) are collateral: they are not
   host paths and must reach the engine verbatim, but MSYS rewrites them to
   `C:\Program Files\Git\workspaces\<name>` (the Git install root), and podman
   rejects the result.

Both problems were reproduced and fixed on a real Windows host (Git Bash,
podman 5.8.2, WSL backend).

## Goals / Non-Goals

**Goals:**

- `claude-docker` starts a container zero-config on a podman-only host.
- A single, canonical way to force an engine that works in every context
  (scripts, CI, editors, non-interactive shells).
- No new installed command name for the project to carry.
- Container-side paths survive intact under Git Bash on Windows.
- The default docker + non-MSYS path stays byte-for-byte identical to today.
- `--help` keeps exiting 0 on a host with no engine installed.

**Non-Goals:**

- A second command (`claude-podman`). Explicitly dropped — see D1.
- Engines beyond docker/podman (nerdctl, containerd/nerdctl, lima's `nerdctl`).
  The allowlist can widen later; there is no demand yet.
- Persisting per-user runtime preference to a config file. The env var is the
  knob; the shell rc / alias is where a user makes it sticky.
- Porting `run.sh` off bash to POSIX `sh`.

## Decisions

### D1: Two tiers — `CLAUDE_DOCKER_RUNTIME` override + docker-first auto-detect. No second command.

An earlier draft added a parallel `claude-podman` command dispatched via
`case "${0##*/}"` (argv[0]), plus a second README install line symlinking it.
The dispatch itself was clean, but it makes the project carry a second command
name forever. Collapsing to an env-var override plus auto-detect covers every
case with one command:

- **Auto-detect (docker-first)** handles the podman-only host with zero config —
  the actual bug in the title.
- **`CLAUDE_DOCKER_RUNTIME`** is the canonical way to force an engine and works
  *everywhere*: CI jobs, editor "run" integrations, and non-interactive shells
  all inherit an env var. This is the honest trade-off to document: an alias
  (`alias claude-podman='CLAUDE_DOCKER_RUNTIME=podman claude-docker'`) only
  resolves at an interactive prompt, so the README presents the env var as the
  mechanism and the alias as optional sugar — never as a PATH-binary
  replacement.

**Alternatives considered:**
- *argv[0] dispatch (`claude-podman`).* Rejected — second command name, second
  install step, and it doesn't help non-interactive/CI callers any more than
  the env var does.
- *podman-first auto-detect.* Rejected — docker is still the more common engine
  and the historical default of this wrapper; docker-first preserves existing
  behaviour on mixed hosts (both installed).

### D2: Allowlist the override to `docker`/`podman`.

`CLAUDE_DOCKER_RUNTIME` is interpolated into the container-runtime invocation
(`"$RUNTIME" run …`), i.e. it names a binary that gets executed with the full
argv. Without a guard, `CLAUDE_DOCKER_RUNTIME=<anything-on-PATH>` would be run
verbatim. A `case` allowlist rejects anything but `docker`/`podman` (and empty,
which means auto-detect) before the value is ever used:

```sh
case "$RUNTIME" in
  ""|docker|podman) ;;
  *) echo "claude-docker: CLAUDE_DOCKER_RUNTIME must be 'docker' or 'podman', got '$RUNTIME'" >&2; exit 1 ;;
esac
```

This guard is worth keeping regardless of the tiering decision.

### D3: Run the selection *after* the argument-parse loop.

Placement matters for two reasons:

1. `-h`/`--help` is handled *inside* the parse loop and exits 0 there. Putting
   the selection block before the loop (e.g. right after `IMAGE=`) would run it
   before the help short-circuit, so `claude-docker --help` on a host with no
   engine would exit 1 — breaking the existing `cli-help` guarantee ("`--help`
   exits 0 even with no docker on PATH"). Placing it just after the loop means
   help has already exited by the time selection runs.
2. A real run on an engine-less host should fail *early*, before any `mktemp`
   staging dir is created or host config is copied. Just-after-the-loop is
   before all of that.

This keeps `cli-help`'s "Modified Capabilities: None" accurate — the help path
is untouched.

### D4: MSYS argv-conversion disable + `cygpath` host-path translation.

Under MSYS/MINGW/Cygwin, set both `MSYS2_ARG_CONV_EXCL='*'` (MSYS2/newer Git
Bash) and `MSYS_NO_PATHCONV=1` (older Git-for-Windows) so the shell stops
rewriting argv. That alone fixes the container-side paths, but it also stops the
shell from translating the *host* bind-mount sources (which legitimately need to
become Windows paths). So we translate those ourselves, centralized in one
helper applied at every bind-source construction site:

```sh
hostpath() {
  if [ "$IS_MSYS" = "1" ] && command -v cygpath >/dev/null 2>&1; then
    cygpath -m "$1"   # e.g. /c/Users/foo -> C:/Users/foo (mixed: drive + forward slashes)
  else
    printf '%s' "$1"
  fi
}
```

`cygpath -m` emits the mixed form (`C:/Users/foo`) that both Docker Desktop and
podman accept in `-v SOURCE:DEST`; the drive-letter colon is handled by the
engine's own Windows-path parsing. Off-MSYS, `hostpath` is the identity
function, so the Linux/macOS argv is unchanged to the byte.

Only bind-mount *sources* are wrapped. Container-side targets, `-w`,
`--add-dir`, tmpfs paths, named-volume names, and env values are left literal —
they must not be translated, and with argv conversion disabled they are passed
through untouched.

**Alternatives considered:**
- *Prefix container paths with `//` to defeat conversion.* Rejected — fragile,
  scatters magic across every path, and doesn't address the host-source side.
- *Blanket `MSYS_NO_PATHCONV` with no host translation.* Rejected — leaves host
  bind sources as `/c/...`, which the native engine may not resolve; `cygpath`
  produces the form the engine actually accepts.

### D5: Keep the child-process + EXIT-trap cleanup; do *not* `exec` the engine.

`run.sh` stages host config under `$HOME/.cache/claude-docker/host.XXXXXX` and
registers an `EXIT` trap to `rm -rf` it after the container exits. `exec`-ing
the engine would replace the shell process, so the trap would never fire and
the staging dir would leak on every run. The wrapper therefore keeps invoking
the engine as a child (`"$RUNTIME" run …`) and lets the trap clean up on return,
exactly as the hardcoded `docker run` did today. The allowlist (D2) still
matters: whether the value is `exec`'d or run as a child, an unvalidated binary
name would still be executed with the full argv.

## Risks / Trade-offs

- **Risk:** docker-first auto-detect picks `docker` on a host where the user
  actually wanted podman (both installed).
  → **Mitigation:** `CLAUDE_DOCKER_RUNTIME=podman` forces it, documented as the
  canonical mechanism. Docker-first matches the wrapper's historical default so
  no existing user's behaviour changes.

- **Risk:** `cygpath` absent under some exotic MSYS setup.
  → **Mitigation:** `hostpath` falls back to the untranslated path when
  `cygpath` is not on PATH, degrading to today's behaviour rather than
  crashing. `cygpath` ships with Git for Windows and MSYS2 by default.

- **Risk:** podman's CLI diverges from docker's for a flag this wrapper uses
  (`--init`, `--security-opt no-new-privileges`, `--cap-add`, `--tmpfs`,
  named volumes).
  → **Mitigation:** all of these are supported by podman's docker-compatible
  CLI and were exercised on the podman 5.8.2 WSL host used to reproduce the
  bug. Any future divergence surfaces at run time with a clear engine error,
  not a silent wrong result.

- **Trade-off:** wrapping every bind source in `hostpath()` touches many lines.
  → **Mitigation:** the change is mechanical and the helper is a no-op
  off-MSYS, so the risk is confined to the Windows path; Linux/macOS output is
  provably unchanged.

## Migration Plan

Purely additive. No existing flag or default changes. On the common case
(docker present, `CLAUDE_DOCKER_RUNTIME` unset, non-MSYS shell) the emitted argv
is identical to today. Rollback is reverting `run.sh` — the selection block, the
`hostpath` wrapping, and the `"$RUNTIME" run` line are the only functional
edits.

## Open Questions

- Should the allowlist widen to `nerdctl` (Rancher Desktop / lima)? Deferred
  until a real user asks; the `case` arm is a one-line change when it does.
- Should the wrapper warn (not error) when both engines are present so users
  know auto-detect chose docker? Current answer: no — silent docker-first
  matches prior behaviour; the statusline / engine banner already makes the
  active engine visible.
