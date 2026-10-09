## Why

With a keyring login on the host (`use_keyring: true` in glab's `config.yml`), the
in-container glab reads `job_token` from the OS keyring even when `GITLAB_TOKEN` is
set, and fails: the container has no D-Bus. No environment variable covers
`job_token`, so forwarding the token alone is not enough.

## What Changes

- Under `--glab`, mount a copy of the host `config.yml` with every `use_keyring:` set
  to `false` read-only over `/root/.config/glab-cli/config.yml`. The host file is not
  touched; the copy lives in the session's stage dir and goes with it.
- Add a scenario for it.

## Capabilities

- `external-cli-tools`: MODIFIED *Credentials opt-in* (`--glab` bullet, one new
  scenario).

## Impact

- `run.sh`, `docs/auth.md`, `tests/test_glab_token.py`. No image change.
