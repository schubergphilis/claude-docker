## 1. Image: install tfenv

- [x] 1.1 Pick a pinned `TFENV_VERSION` (latest stable tfenv tag) and compute the sha256 of its release source archive from `github.com/tfutils/tfenv`; record both as Dockerfile `ARG`s alongside the existing `*_VERSION` / `*_SHA256` ARGs (single hash is fine — tfenv is a pure bash script archive, arch-independent)
- [x] 1.2 Add a Dockerfile `RUN` block that downloads the pinned tfenv archive, runs `sha256sum -c` against `TFENV_SHA256`, extracts to `/opt/tfenv`, and symlinks `/opt/tfenv/bin/tfenv` (and `terraform` shim) onto `/usr/local/bin/`; place the block after the `uv` block and before the `npm install -g` block so heavier layers above stay cached
- [x] 1.3 Verify the build: `docker build -t claude-code:local ./claude-docker` succeeds on the local arch and `docker run --rm claude-code:local tfenv --version` prints a version (verified: `tfenv 3.0.0`; `terraform version` before any install exits 1 with "Version could not be resolved")
- [x] 1.4 Verify negative path: temporarily flip one byte of `TFENV_SHA256`, rerun `docker build`, confirm the build fails at `sha256sum -c` before tfenv is installed; revert the change (verified: build aborted at the tfenv RUN block with exit 1; original sha256 restored)

## 2. Wrapper: --tfe flag

- [x] 2.1 In `run.sh`, add `WITH_TFE=0` alongside the other `WITH_*` initializers and a `--tfe) WITH_TFE=1 ;;` arm in the case statement
- [x] 2.2 Under `--tfe`, append `-v "$HOME/.terraform.d/credentials.tfrc.json:/root/.terraform.d/credentials.tfrc.json:ro"` to `MOUNT_ARGS` only when the host file exists (silent no-op otherwise, mirroring `--gh`'s silent fallback); follow the same `[ -f ... ]` guard pattern used for `~/.aws/config`
- [x] 2.3 Under `--tfe`, add `TF_TOKEN_app_terraform_io` to the `ENV_VARS` array so the existing `[ -n "${!v:-}" ]` filter forwards it only when set on the host
- [x] 2.4 When `EPHEMERAL=0` and `WITH_TFE=0`, append `--tmpfs /root/.terraform.d` to `MOUNT_ARGS` next to the existing `gh`/`glab` tmpfs masks, with a one-line comment pointing at the same persistence-leak rationale
- [x] 2.5 Append `tfe` to `DOCKER_FLAGS` when `WITH_TFE=1` so the statusline tag reflects the opt-in
- [x] 2.6 Update the `print_help` heredoc with a `--tfe` row matching the `--aws`/`--gh`/`--glab` style (one-line summary: mounts `~/.terraform.d/credentials.tfrc.json` read-only and forwards `TF_TOKEN_app_terraform_io`; targets `app.terraform.io`)

## 3. Smoke tests against scenarios

- [x] 3.1 No-flag invariants: `claude-docker ~/repo` (no flags) → inside the container, `/root/.terraform.d/` is empty and `echo $TF_TOKEN_app_terraform_io` is empty, even after a prior `--tfe` session that ran `terraform login` (verified: tmpfs mask shows empty dir; `TF=empty`)
- [x] 3.2 `--tfe` file mount: with a host `~/.terraform.d/credentials.tfrc.json` present, `claude-docker --tfe ~/repo` exposes the file read-only inside the container; an in-container `: > /root/.terraform.d/credentials.tfrc.json` fails with EROFS (verified: file readable in container, write attempt returned `Read-only file system`)
- [x] 3.3 `--tfe` env-var forwarding: with `TF_TOKEN_app_terraform_io=<token>` exported on the host, `claude-docker --tfe ~/repo` forwards it; without `--tfe`, it does not (verified: `TF=tfc_smoke_xyz` with --tfe, `TF=empty` without)
- [x] 3.4 `--tfe` silent absence: with no host credentials file and no env var set, `claude-docker --tfe ~/repo` starts cleanly (no error printed) and `/root/.terraform.d/` is empty (verified: container started cleanly, empty dir, no env var set)
- [x] 3.5 Persistence-leak guard: run `claude-docker --tfe ~/repo`, complete `terraform login app.terraform.io` inside, exit, then run `claude-docker ~/repo` (no flag) — confirm `/root/.terraform.d/` is empty inside the second session (verified: simulated a `terraform login` write to `/root/.terraform.d/credentials.tfrc.json` in the `claude-code-root` named volume; subsequent no-flag session with the tmpfs mask shows empty dir, `test -e` returns false → "hidden as expected")
- [x] 3.6 `tfenv install` end-to-end: in a workspace containing `.terraform-version` with `1.9.5`, `tfenv install` downloads from `releases.hashicorp.com` and installs; `terraform version` reports `1.9.5` (verified: downloaded `terraform_1.9.5_linux_arm64.zip` from releases.hashicorp.com, installed under `/opt/tfenv/versions/1.9.5/`, `terraform version` reports `Terraform v1.9.5 on linux_arm64`)
- [x] 3.7 Statusline tag includes `tfe`: launch `claude-docker --tfe --gh ~/repo` and confirm the statusline prefix shows `docker:gh,tfe` (or whatever order the existing builder emits) (verified by static inspection of `run.sh:233-238` — append order is gh, aws, glab, tfe; with `--gh --tfe` set, `CLAUDE_DOCKER_FLAGS=gh,tfe` and the statusline wrapper at `run.sh:281-289` prepends `docker:gh,tfe`)

## 4. Documentation

- [x] 4.1 Update the "Bundled CLIs on the default PATH" line at the top of `README.md` to include `tfenv`
- [x] 4.2 Add a `--tfe` row to the **Credential opt-in** table in `README.md`, matching the `--aws`/`--gh`/`--glab` voice (mention: file mount, env-var forwarding, tmpfs mask without flag, scope = `app.terraform.io` only)
- [x] 4.3 Extend the **Auth model** section with a `--tfe` row covering source of credentials and the persistence-mask rule
- [x] 4.4 Update the **Threat model** "Runtime code-fetch" bullet to add `tfenv install` as a third primitive (note: pulls from `releases.hashicorp.com`, terraform binary is *not* sha256-pinned in the image because the project picks the version)
- [x] 4.5 Add a short paragraph (under Auth model or a new "Terraform Cloud" sub-section) documenting the standard usage flow: `terraform login app.terraform.io` once on the host → `claude-docker --tfe ~/repo` → `tfenv install` to materialize a project-pinned terraform → `terraform plan`

## 5. Validation

- [x] 5.1 `openspec validate add-tfe-support --strict` exits 0
- [x] 5.2 `claude-docker --help` output round-trips: every wrapper flag listed in the help text has a matching arm in the case statement and vice versa (including the new `--tfe`)
- [x] 5.3 Spot-check that `--ephemeral` still works alongside `--tfe`: `claude-docker --ephemeral --tfe ~/repo` mounts the credentials file and forwards the env var but skips the named volumes (so the tmpfs mask block is bypassed cleanly) — verified statically in `run.sh`: TFC mount/env blocks run unconditionally on `WITH_TFE=1` regardless of `EPHEMERAL`; tmpfs mask block is gated by `EPHEMERAL=0` (correctly skipped when `--ephemeral` since no named volume is mounted to mask)
