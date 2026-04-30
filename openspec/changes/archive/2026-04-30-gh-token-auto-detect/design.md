## Context

`run.sh` currently forwards `GH_TOKEN` and `GITHUB_TOKEN` only when they are
already set in the host environment. Users who rely on `gh auth login` (which
stores credentials in the macOS Keychain via the `gh` CLI) have no env vars to
forward and receive an unauthenticated container even when `--gh` is passed.
The `gh` CLI provides `gh auth token` to retrieve the active token from the
Keychain without requiring the user to export anything manually.

## Goals / Non-Goals

**Goals:**
- When `--gh` is set and no token env var is present, automatically obtain the
  token via `gh auth token` and inject it as `GH_TOKEN`.
- Fail silently when `gh` is absent or `gh auth token` returns non-zero —
  the existing manual flow (logging in inside the container) remains available.

**Non-Goals:**
- Caching the token between runs (each invocation calls `gh auth token` fresh).
- Supporting `gh auth token --hostname` for GitHub Enterprise (straightforward
  extension if needed later, not in scope now).
- Changing behaviour when `GH_TOKEN` or `GITHUB_TOKEN` is already set.

## Decisions

### Decision: Fall back only when both env vars are absent

Check `GH_TOKEN` and `GITHUB_TOKEN` before calling `gh auth token`. If either
is already set, skip the fallback. This preserves the current behaviour exactly
for users who export tokens manually, and avoids an unnecessary subprocess.

### Decision: Forward the auto-detected token as `GH_TOKEN`, not as a new var

`gh` and most tools that honour GitHub tokens read `GH_TOKEN` or `GITHUB_TOKEN`.
Injecting as `GH_TOKEN` (same var already in the forwarding list) keeps the
container environment consistent with the env-var flow and requires no changes
to how the container consumes the credential.

### Decision: Swallow `gh auth token` failures silently

If `gh` is not on PATH, the user is not logged in, or the command fails for any
reason, `run.sh` should continue without a token rather than aborting. The
`--gh` flag already documents that authentication can be completed inside the
container; the fallback is a convenience, not a guarantee. Emitting a warning
(but not exiting) was considered but rejected — it would produce noise for users
who intentionally omit the token and plan to log in inside.

### Decision: Capture output with `$(gh auth token 2>/dev/null)`

Redirect stderr so any `gh` error messages don't pollute the terminal. Only
inject the token if the captured string is non-empty, guarding against `gh`
exiting 0 with no output (shouldn't happen but defensive).

## Risks / Trade-offs

- [`gh auth token` is slow on some systems] → Acceptable; it only runs when
  `--gh` is set and no env var is present. One subprocess per `claude-docker`
  invocation is negligible.
- [Token logged in shell history or process list] → The token is captured into a
  shell variable and passed via `-e GH_TOKEN=<value>` in `docker run`. Docker
  exposes env vars to all processes in the container, same as the existing
  env-var flow. No new exposure.
- [`gh` on PATH but for a different GitHub account than expected] → The user
  controls which account `gh` is logged into on the host. Same responsibility as
  the existing `gh auth login` in-container flow.
