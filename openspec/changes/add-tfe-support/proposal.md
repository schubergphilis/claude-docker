## Why

Developers using claude-docker increasingly work with Terraform Cloud (app.terraform.io)
where plans are triggered by GitHub PR/push events. To inspect plan output, debug
failed runs, or run ad-hoc API queries against TFC from inside the container,
Claude needs an authenticated `app.terraform.io` session — today there is no path
short of pasting tokens into the container by hand.

Baking a pinned `terraform` binary into the image is rejected: Terraform versions
are project-pinned (`required_version`, `.terraform-version`) and any single
shipped version will drift against real workspaces. We need authenticated TFC
access without owning a terraform-version-management problem.

## What Changes

- **Add `--tfe` opt-in flag** to `run.sh` that mounts the host's
  `~/.terraform.d/credentials.tfrc.json` read-only into the container. Same
  pattern as `--aws` / `--gh` / `--glab`: no flag → no credentials reach the
  container.
- **Forward `TF_TOKEN_app_terraform_io`** from the host environment when
  `--tfe` is set, for users who export tokens instead of using the credentials
  file.
- **Mask `/root/.terraform.d/` with tmpfs** when `--tfe` is not set, so a prior
  in-container login persisted in `claude-code-root` cannot leak into a
  session that did not opt in. Matches the existing rule for `gh`/`glab`.
- **Install `tfenv`** in the image so users can fetch a project-pinned
  terraform version on demand (`tfenv install`, auto-detects
  `.terraform-version`). The image SHALL NOT ship any pre-installed terraform
  binary — version selection is the project's responsibility, not the image's.
- **Document the runtime-fetch risk** in the threat model: `tfenv install`
  downloads and executes a terraform binary from `releases.hashicorp.com` at
  runtime, in the same class as the already-documented `pnpm dlx` / `uvx`.
- **Update README** "Bundled CLIs" line and add usage docs for `--tfe`.

Out of scope (deliberately): self-hosted Terraform Enterprise hostnames, Sentinel
policy tooling, `tfc-cli`/community wrappers, automatic VCS-run polling. The
credentials file format already supports custom hosts so a future flag extension
is straightforward, but only `app.terraform.io` is targeted now.

## Capabilities

### New Capabilities

None. This change extends an existing capability rather than introducing a new one.

### Modified Capabilities

- `external-cli-tools`: adds the `--tfe` opt-in flag (credential mount +
  env-var forwarding + tmpfs masking when not set) and adds `tfenv` to the
  set of bundled binaries on the default PATH. The "version pinned and
  sha256-verified" requirement applies to `tfenv` itself; the terraform
  binaries that `tfenv` fetches at runtime are intentionally not pinned by
  this image.
- `package-managers`: the threat-model documentation requirement is extended
  to cover `tfenv install` as a third runtime code-fetch primitive (alongside
  `pnpm dlx` / `uvx`).

## Impact

- **Code**: `claude-docker/Dockerfile` (install `tfenv`, pin its version + sha256),
  `claude-docker/run.sh` (parse `--tfe`, mount credentials, forward env, apply
  tmpfs mask).
- **Docs**: `claude-docker/README.md` (bundled CLIs list, usage section,
  threat-model bullet).
- **Specs**: deltas to `external-cli-tools` and `package-managers`.
- **No breaking changes**: existing flags and defaults unchanged; `--tfe` is
  purely additive.
- **Dependencies**: adds `tfenv` (single bash script, MIT-licensed, ~25KB).
  Adds runtime network egress to `releases.hashicorp.com` *only when* the user
  invokes `tfenv install` inside the container.
