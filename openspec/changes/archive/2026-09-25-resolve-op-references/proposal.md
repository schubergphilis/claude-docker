## Why

Every credential channel in `run.sh` assumes the secret is already plaintext on the
host: an exported env var or a file. Using `--glab`, `--tfe` or `--registry` therefore
means keeping a long-lived token exported in a shell profile — the standing-plaintext
posture the rest of the threat model works to avoid. There is no secret-manager
integration of any kind.

Closes [#73](https://github.com/schubergphilis/claude-docker/issues/73).

## What Changes

- **Resolve `op://` references on the host.** When a credential env var that an opt-in
  forwards holds a value starting with `op://`, `run.sh` resolves it with `op read`
  (the user's own 1Password CLI) before launch and forwards the resolved value by bare
  name, exactly as a plaintext value is forwarded today. It hooks the shared forward
  loop, so it composes with every opt-in without per-provider plumbing. Under `--gh`,
  `GH_TOKEN` / `GITHUB_TOKEN` are resolved the same way before they are handed to the
  auth-proxy sidecar.
- **Fail loudly.** An `op://` value is an explicit request, so a missing `op` or a failed
  read exits 1 before any container starts. Errors name only the variable — never the
  reference path or the secret; `op`'s own stderr is dropped because it echoes the path.
- **README** documents the syntax under *Credential opt-in*, and `OP_SERVICE_ACCOUNT_TOKEN`
  on the host as the unattended path (so `op read` does not wait on a desktop unlock).

Not in scope:

- **`op` inside the container.** Forwarding a service-account token would give the agent
  every secret that account reaches, for longer than the session. Host-side resolution
  keeps the vault credential out of the container entirely.
- **Other schemes** (`vault://`, `aws-secrets://`). One scheme, because there is one
  concrete need.
- **A timeout on `op read`.** No portable tool for it (`timeout` is not on stock macOS);
  the service-account token is the documented unattended path.
- **A `design.md`.** The design is the one in the issue; nothing beyond it to record.

## Capabilities

- `external-cli-tools` — ADDED: *Secret-manager references in forwarded credentials*.
  Added as its own requirement rather than a MODIFIED *Credentials opt-in*, because it
  applies across every opt-in instead of belonging to any one flag.

## Impact

- `run.sh` only. No image change, no new flag, pin or tmpfs mask; `op` stays an optional
  host dependency, needed only by users who write `op://` values.
