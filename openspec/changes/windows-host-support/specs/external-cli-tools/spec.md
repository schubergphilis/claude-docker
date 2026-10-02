## MODIFIED Requirements

### Requirement: Credentials opt-in

Host credentials (files or env vars) SHALL NOT reach the container unless the user explicitly opts in per-run. `run.sh` defaults to no credential mounts and no token env forwarding. Opt-ins are granted via dedicated flags:

- `--aws`: mount `~/.aws/config` at `/root/.aws/config:ro` and, when present, `~/.aws/sso/` at `/root/.aws/sso:ro`; forward `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` when set on the host.
- `--gh`: discover the host token from `GH_TOKEN` or `GITHUB_TOKEN`; if neither
  is set, `run.sh` SHALL attempt to retrieve the active token by running
  `gh auth token` on the host. A discovered token SHALL be provided only to the
  per-session auth proxy sidecar (see capability `gh-auth-proxy`) — it SHALL
  NOT be forwarded into the agent container, which instead receives the
  placeholder `GH_TOKEN=claude-docker-proxy` and reaches GitHub through the
  sidecar. If `gh` is not on the host PATH or the command fails, `run.sh`
  SHALL continue silently without a token and without a sidecar.
- `--gh-direct`: legacy escape hatch. Same token discovery as `--gh`, but the
  token is forwarded directly into the agent container as `GH_TOKEN` and no
  sidecar is started. Intended for custom-hostname GitHub (Enterprise Server /
  `*.ghe.com`) and hosts that cannot run the sidecar. Passing `--gh` and
  `--gh-direct` together SHALL exit with an error. The mode SHALL surface as
  a distinct `gh-direct` entry in `CLAUDE_DOCKER_FLAGS` so the statusline tag
  distinguishes it from proxied `gh`.
- `--glab`: mount the platform-appropriate glab config dir — `~/Library/Application Support/glab-cli` on macOS, `%APPDATA%\glab-cli` on Windows (Git Bash), `~/.config/glab-cli` on Linux and as the fallback everywhere — at `/root/.config/glab-cli:ro`; forward `GITLAB_TOKEN` and `GITLAB_HOST` when set on the host. If `GITLAB_TOKEN` is not set, `run.sh` SHALL attempt to retrieve the host glab token by running `glab config get token --host <host>`, where `<host>` is the hostname of glab's default host (`glab config get host`, which honours `GITLAB_HOST`; `gitlab.com` if empty). That command also reads tokens glab stored in the OS keyring. A discovered token SHALL be forwarded as `GITLAB_TOKEN` by bare name so it never appears in argv. If `glab` is not on the host PATH or returns no token, `run.sh` SHALL continue silently without one.
- `--tfe`: when present on the host, mount the `terraform login` credentials file — `%APPDATA%\terraform.d\credentials.tfrc.json` on Windows (Git Bash), `~/.terraform.d/credentials.tfrc.json` on Linux/macOS and as the fallback everywhere — at `/root/.terraform.d/credentials.tfrc.json:ro`; forward `TF_TOKEN_app_terraform_io` when set on the host. Targets `app.terraform.io` (HCP Terraform); self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are out of scope for this opt-in.
- `--az`: forward `AZURE_DEVOPS_EXT_PAT` and `AZURE_DEVOPS_ORG_URL` when set on the host, and SHALL NOT mount any host `~/.azure` file: the PAT is the whole credential, and the profile would only carry tenant / subscription IDs and the account name into the container. `AZURE_DEVOPS_ORG_URL` SHALL be the only source of the Azure DevOps hostname — nothing SHALL assume `dev.azure.com`, so Azure DevOps Server (on-prem, custom hostname) works the same as Services. `run.sh` SHALL NOT attempt host-side PAT discovery (`az` has no command that prints a usable PAT). When `CLAUDE_DOCKER_AZ_CA` is set on the host, `run.sh` SHALL mount the file it names read-only at `/usr/local/share/ca-certificates/claude-docker-az.crt`, the entrypoint SHALL install it into the system trust store before the privilege drop, and `az` SHALL use the system bundle; the host value itself SHALL NOT be forwarded. When it is set but does not name a file, `run.sh` SHALL exit 1 before starting any container. The host's `REQUESTS_CA_BUNDLE` SHALL NOT be read, since it is often set for unrelated reasons. The certificate is trusted for every TLS connection in the container, not only the Azure DevOps Server; the documentation SHALL say so. Targets the `azure-devops` extension only; general Azure resource management and its credentials (`ARM_*`, `AZURE_CLIENT_SECRET`, service principals) are out of scope for this opt-in.

All credential bind-mounts SHALL be read-only so a compromised container cannot rewrite host config or tokens. `~/.aws/credentials` and `~/.aws/cli/cache/` SHALL NEVER be mounted, even under `--aws`. Likewise nothing under `~/.azure/` SHALL be mounted under `--az` — in particular never the Azure token caches `msal_token_cache.json` or `accessTokens.json`.

The container's own `/root/.aws/cli/cache/` SHALL NOT survive the session that
wrote it. The AWS CLI caches assume-role and SSO-derived STS credentials there,
and `/root` is a persistent volume shared by every session, so without a mask
that cache outlives the run whose opt-in produced it. This mirrors the reason
the host path is never mounted: the same material is at stake whether it was
copied in from the host or derived inside the container.

#### Scenario: No flags means no credentials

- **GIVEN** host has `~/.aws/config`, `~/.config/glab-cli/config.yml`, `~/.terraform.d/credentials.tfrc.json`, and `GH_TOKEN=ghp_x` and `TF_TOKEN_app_terraform_io=tfc_x` exported
- **AND** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `/root/.aws/` is empty inside the container
- **AND** `/root/.config/glab-cli/` is empty inside the container
- **AND** `/root/.terraform.d/` is empty inside the container
- **AND** `echo $GH_TOKEN` inside the container is empty
- **AND** `echo $TF_TOKEN_app_terraform_io` inside the container is empty
- **AND** `/root/.azure/` is empty inside the container and `echo $AZURE_DEVOPS_EXT_PAT` is empty
- **AND** `gh auth status` inside the container reports "not logged in"

#### Scenario: --aws grants scoped AWS access

- **GIVEN** the host has completed `aws sso login --profile X` and exports `AWS_PROFILE=X`
- **WHEN** user runs `claude-docker --aws ~/repo`
- **THEN** `aws sts get-caller-identity` inside the container returns the host's identity
- **AND** `~/.aws/credentials` is not present inside the container
- **AND** writes to `/root/.aws/config` from inside the container fail with EROFS
- **AND** writes to `/root/.aws/sso/` from inside the container fail with EROFS
- **AND** `/root/.aws/cli/cache/` is empty at session start and its contents do not persist to a later session

#### Scenario: --glab grants read-only token access

- **GIVEN** the host has a valid `~/.config/glab-cli/config.yml`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `glab auth status` reports "logged in" without prompting
- **AND** writes to `/root/.config/glab-cli/` from inside the container fail with EROFS

#### Scenario: --glab falls back to the host glab token

- **GIVEN** `GITLAB_TOKEN` is not set on the host and `GITLAB_HOST=https://gitlab.example.com` is
- **AND** host `glab auth login` stored a token for `gitlab.example.com`, in `config.yml` or the OS keyring
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the container receives that token as `GITLAB_TOKEN`, and `GITLAB_HOST`
- **AND** neither token nor host value appears in the `docker run` argv

#### Scenario: --glab discovers a keyring-held token

- **GIVEN** `GITLAB_TOKEN` is not set on the host
- **AND** host glab's `config.yml` has `use_keyring: true` and no `token` for the default host, the token living only in the OS keyring
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the token returned by host `glab config get token --host <host>` is forwarded as `GITLAB_TOKEN`

#### Scenario: --glab keeps an explicit GITLAB_TOKEN

- **GIVEN** `GITLAB_TOKEN` is set on the host
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** host `glab` is not asked for a token and the container receives the host's `GITLAB_TOKEN`

#### Scenario: --glab is silent when glab is unavailable

- **GIVEN** `GITLAB_TOKEN` is not set on the host
- **AND** `glab` is not on the host PATH, or has no token for the default host
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** the container starts without `GITLAB_TOKEN` and no error is printed

#### Scenario: --glab finds the Windows config dir under %APPDATA%

- **GIVEN** `run.sh` runs under Git Bash on Windows
- **AND** the host glab config lives at `%APPDATA%\glab-cli`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** that directory is mounted read-only at `/root/.config/glab-cli`

#### Scenario: --gh keeps the host token out of the agent container

- **GIVEN** `GH_TOKEN=ghp_x` is exported in the host shell
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `echo $GH_TOKEN` inside the agent container prints `claude-docker-proxy`
- **AND** `gh api /user` inside the agent container succeeds via the sidecar

#### Scenario: --gh falls back to gh auth token for the sidecar

- **GIVEN** neither `GH_TOKEN` nor `GITHUB_TOKEN` is set in the host shell
- **AND** the host has `gh` on PATH and the user is authenticated (`gh auth status` succeeds)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** authenticated GitHub access works inside the agent container
- **AND** the token returned by host `gh auth token` is not present in the agent container's environment

#### Scenario: --gh is silent when gh is unavailable

- **GIVEN** neither `GH_TOKEN` nor `GITHUB_TOKEN` is set in the host shell
- **AND** `gh` is not on the host PATH (or `gh auth token` exits non-zero)
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** the container starts without a sidecar, without a `GH_TOKEN` env var, and no error is printed

#### Scenario: --gh-direct restores legacy forwarding

- **GIVEN** `GH_TOKEN=ghp_x` is exported in the host shell
- **WHEN** user runs `claude-docker --gh-direct ~/repo`
- **THEN** `echo $GH_TOKEN` inside the agent container prints `ghp_x`
- **AND** no sidecar container is started

#### Scenario: --gh and --gh-direct together are rejected

- **WHEN** user runs `claude-docker --gh --gh-direct ~/repo`
- **THEN** `run.sh` exits non-zero with an error naming the conflicting flags
- **AND** no container or sidecar is started

#### Scenario: --tfe mounts host TFC credentials read-only

- **GIVEN** the host has a valid `~/.terraform.d/credentials.tfrc.json` with an `app.terraform.io` token entry
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** `/root/.terraform.d/credentials.tfrc.json` inside the container contains the host file's contents
- **AND** writes to `/root/.terraform.d/credentials.tfrc.json` from inside the container fail with EROFS

#### Scenario: --tfe forwards host TF_TOKEN_app_terraform_io

- **GIVEN** `TF_TOKEN_app_terraform_io=tfc_xyz` is exported in the host shell
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** `echo $TF_TOKEN_app_terraform_io` inside the container prints `tfc_xyz`

#### Scenario: --tfe is silent when neither file nor env var is set

- **GIVEN** the host has no `~/.terraform.d/credentials.tfrc.json` and no `TF_TOKEN_app_terraform_io` exported
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** the container starts without error
- **AND** `/root/.terraform.d/` inside the container is empty
- **AND** `echo $TF_TOKEN_app_terraform_io` inside the container is empty

#### Scenario: --tfe finds the Windows credentials file under %APPDATA%

- **GIVEN** `run.sh` runs under Git Bash on Windows
- **AND** `terraform login` wrote `%APPDATA%\terraform.d\credentials.tfrc.json` on the host
- **WHEN** user runs `claude-docker --tfe ~/repo`
- **THEN** `/root/.terraform.d/credentials.tfrc.json` inside the container contains that file's contents, mounted read-only

#### Scenario: --az forwards the PAT and the org URL

- **GIVEN** `AZURE_DEVOPS_EXT_PAT=pat_x` and `AZURE_DEVOPS_ORG_URL=https://devops.example.com/DefaultCollection` are exported in the host shell
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** both variables are set inside the container with the host's values
- **AND** `az devops project list` inside the container targets `https://devops.example.com/DefaultCollection` without an `--org` argument

#### Scenario: --az mounts only the non-secret az config

- **GIVEN** the host has `~/.azure/azureProfile.json`, `~/.azure/clouds.config` and `~/.azure/msal_token_cache.json`
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** none of those files is present under `/root/.azure` inside the container
- **AND** `AZURE_DEVOPS_EXT_PAT` carries the host's value

#### Scenario: --az trusts the host REQUESTS_CA_BUNDLE

- **GIVEN** the host exports `CLAUDE_DOCKER_AZ_CA=~/.azure/tfs-ca.pem` naming a PEM CA certificate
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** the certificate is present in `/etc/ssl/certs/ca-certificates.crt` inside the container
- **AND** `az` resolves `REQUESTS_CA_BUNDLE` to `/etc/ssl/certs/ca-certificates.crt`, not the host path

#### Scenario: --az ignores the host REQUESTS_CA_BUNDLE

- **GIVEN** the host exports `REQUESTS_CA_BUNDLE` naming a PEM file and does not set `CLAUDE_DOCKER_AZ_CA`
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** no file is mounted at `/usr/local/share/ca-certificates/claude-docker-az.crt`

#### Scenario: --az with a missing REQUESTS_CA_BUNDLE fails loudly

- **GIVEN** the host exports `CLAUDE_DOCKER_AZ_CA=/nonexistent.pem`
- **WHEN** user runs `claude-docker --az ~/repo`
- **THEN** `run.sh` exits 1 with an error naming the path and starts no container
