## Why

Follow-ups from the reviews of #127, tracked in
[#131](https://github.com/schubergphilis/claude-docker/issues/131). The `--glab` host
parsing that #127 added strips the port from `GITLAB_HOST` and glab's default host (a
regression against `main`), picks the wrong host when the URL has an `@` in its path or
password, and asks for the same host twice. When `git rev-parse --git-common-dir` fails,
it reads a host file `/config`.

## What Changes

- Keep the port for `GITLAB_HOST`, glab's default host and `http(s)://` remotes. Drop it
  only for `ssh://` and scp-style remotes, where it is the SSH port.
- Strip the URL path before the user info.
- Skip a host that was already tried, in both the lookup and the warning.
- Skip the origin lookup when the common git dir can't be resolved.
- Add a scenario for the `GITLAB_HOST` port.

Not in scope: renaming the scenario *--glab is silent when glab is unavailable*, whose
body already requires a warning. OpenSpec 1.13.2 refuses to drop a scenario under
MODIFIED, and refuses REMOVED + ADDED of the same requirement in one change.

## Capabilities

- `external-cli-tools`: MODIFIED *Credentials opt-in* (`--glab` bullet, one new
  scenario).

## Impact

- `run.sh`, `docs/auth.md`, `tests/test_glab_token.py`. No image change.
