## Why

`--gh` / `--gh-direct` fall back to host `gh auth token`, so a `gh auth login` user
exports nothing. `--glab` has no equivalent: it only forwards an exported
`GITLAB_TOKEN`, and the read-only `glab-cli` mount carries a token only when glab wrote
it into `config.yml`. When host glab stored it in the OS keyring the container comes up
silently unauthenticated. `GITLAB_HOST` is not forwarded either, so a self-managed
instance can't be targeted.

Closes [#71](https://github.com/schubergphilis/claude-docker/issues/71).

## What Changes

- **Discover the host glab token.** Under `--glab`, when `GITLAB_TOKEN` is unset, `run.sh`
  runs `glab config get token --host <host>` on the host, with `<host>` the hostname of
  glab's default host (`glab config get host`: `GITLAB_HOST`, else config `host`, else
  `gitlab.com`). Per glab's `internal/config/config.go` (`GetWithSource`), that lookup
  reads the OS keyring when the host uses it; without `--host` it never consults
  per-host tokens at all, so `--host` is required. glab has no `auth token` subcommand.
- **Precedence and disposition mirror gh:** an explicit `GITLAB_TOKEN` (including an
  `op://` value, resolved first) wins; a missing glab or no token is a silent skip; the
  token is forwarded by bare name, never on argv.
- **Forward `GITLAB_HOST`** alongside `GITLAB_TOKEN`, so discovery and the container agree
  on the instance.
- README `--glab` row and `docs/auth.md` updated.

Not in scope:

- **Proxy isolation for glab** (#12) — this changes discovery, not disposition.
- **A new flag.** Discovery rides the existing `--glab` opt-in, as gh's does.
- **A `design.md`.** The design is the one in the issue.

## Capabilities

- `external-cli-tools` — MODIFIED: *Credentials opt-in* (`--glab` bullet, three
  scenarios).

## Impact

- `run.sh` only; no image change, pin or tmpfs mask change.
