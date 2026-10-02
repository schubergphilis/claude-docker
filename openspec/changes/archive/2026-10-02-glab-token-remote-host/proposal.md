## Why

`--glab` token discovery only asks host glab for its *default* host's token
(`GITLAB_HOST`, else `config.yml` `host`, else `gitlab.com`). A user logged in to a
self-managed instance that isn't glab's default gets no `GITLAB_TOKEN`, and it fails
silently. In the container, the read-only `config.yml` still says `use_keyring: true` for
that host, so glab goes to the keyring, which has no D-Bus there, and errors out
(`dbus-launch` not found) before it sends a request. Plain HTTPS API calls work, which
makes it look like a glab bug. Setting `GITLAB_HOST` alone on the host fixes it, which
confirms the lookup asked for the wrong host.

Closes [#126](https://github.com/schubergphilis/claude-docker/issues/126).

## What Changes

- **Try the workspace remote's host.** With `GITLAB_HOST` unset, discovery tries the
  first workspace's `remote.origin.url` host before glab's default host. The URL is read
  with `git config --file` (no includes, no repo hooks), and symlinked `.git` /
  `.git/config` are skipped, as the git-config overlay already does.
- **Warn instead of staying silent** when `--glab` ends up with no token. One stderr
  line names the hosts tried and the `GITLAB_TOKEN` / `GITLAB_HOST` remedies.
- An explicit `GITLAB_HOST` still pins the lookup to that one host.

Not in scope:

- **A keyring / D-Bus in the image.** A secret store in the container goes against the
  threat model, and glab never reaches the keyring once `GITLAB_TOKEN` is set.
- **Every remote of every workspace.** Only the first workspace's `origin`. A second
  instance still needs an explicit `GITLAB_TOKEN` / `GITLAB_HOST`.

The remote URL comes from the (container-writable) workspace, so it can steer which of
the user's own glab tokens is forwarded. Only tokens the user already holds can be
picked, and `--glab` is the opt-in to forwarding a GitLab token at all.

## Capabilities

- `external-cli-tools` — MODIFIED: *Credentials opt-in* (`--glab` bullet; one new
  scenario). The scenario *--glab is silent when glab is unavailable* keeps its
  title, because the validator won't drop or rename a scenario under MODIFIED, but its
  body now requires the warning.

## Impact

- `run.sh`, README, `docs/auth.md`, `tests/test_glab_token.py`. No image change.
