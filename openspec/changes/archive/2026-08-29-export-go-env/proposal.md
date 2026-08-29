## Why

The image installs Go but exports none of its environment. `GOROOT`, `GOPATH`,
and `GOBIN` exist only as `go env` defaults, computed by the toolchain from
`HOME` at invocation time. Anything that is not the `go` binary — a Makefile
that references `$(GOBIN)`, a Taskfile, a CI helper script, a linter wrapper —
reads the process environment, finds the variables unset, and either guesses or
fails. The values are already fixed and known at build time, so leaving them
implicit buys nothing.

Separately, the `pip install --user` / `uv tool install` prefix
`/root/.local/bin` is not on PATH at all, so a tool a session installs that way
is not runnable by name. That directory sits in the persistent
`claude-code-root` volume and is writable by the agent — exactly the property
that already pins `/root/go/bin` to last position — so it can be added, but only
behind every system path.

## What Changes

- Export `GOROOT=/usr/local/go`, `GOPATH=/root/go`, `GOBIN=/root/go/bin` as
  image `ENV`, so they hold for `docker run`, `docker exec`, and non-login
  shells alike, spelled against a literal `/root`.
- Add `/root/.local/bin` to the default PATH in second-to-last position, ahead
  of `/root/go/bin` and behind every system path.
- Broaden the PATH-ordering requirement from "GOPATH binaries" to
  volume-persisted directories generally, so the guarantee covers both
  agent-writable entries rather than naming only the one that existed first.
- Assert both in `smoke/assert-in-container.sh`. The existing non-shadowing
  requirement has never had a test; the new check enforces the ordering, the
  resolution of `git` to `/usr/bin/git`, and the three exported values.

Not in scope: setting `TASK_X_REMOTE_TASKFILES=1`. go-task's remote `includes:`
left experimental in 3.53.1, so the feature is on by default and setting the
opt-in only makes every `task` invocation warn that the experiment is released.
It stays a runtime code-fetch primitive in the same class as `pnpm dlx`, `uvx`,
and `go install`, and `task` still prompts before trusting a new remote
Taskfile checksum. The Dockerfile records this as a comment so the next reader
does not re-derive it.

Not in scope: making the image itself install anything into `/root/.local/bin`.
Nothing in the build writes there today; the entry is for session-installed
tools only.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `go-toolchain`: adds a requirement that the Go environment is exported by the
  image rather than left to `go env` defaults, and replaces the GOPATH-specific
  PATH-ordering requirement with one covering every agent-writable,
  volume-persisted PATH entry.

## Impact

- `Dockerfile` — one new `ENV` instruction for the Go variables and a reordered
  `PATH`. No new layer content, no download, no size change beyond the
  environment block.
- `smoke/assert-in-container.sh` — a `check_path_order()` function and two
  helpers; adds six assertions to every smoke cell.
- No change to `run.sh`, the entrypoint, the capability set, or the credential
  model. The privilege drop is unaffected: `entrypoint.sh` execs
  `runuser -u claude` (not `-l`), so the image PATH reaches the agent unchanged
  either way — which is why its ordering is the security-relevant artifact.
