# external-cli-tools — delta

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
- `--glab`: mount the platform-appropriate glab config dir — `~/Library/Application Support/glab-cli` on macOS, `~/.config/glab-cli` on Linux — at `/root/.config/glab-cli:ro`; forward `GITLAB_TOKEN` when set on the host.

All credential bind-mounts SHALL be read-only so a compromised container cannot rewrite host config or tokens. `~/.aws/credentials` and `~/.aws/cli/cache/` SHALL NEVER be mounted, even under `--aws`.

#### Scenario: No flags means no credentials

- **GIVEN** host has `~/.aws/config`, `~/.config/glab-cli/config.yml`, and `GH_TOKEN=ghp_x` exported
- **AND** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo`
- **THEN** `/root/.aws/` does not exist inside the container
- **AND** `/root/.config/glab-cli/` is empty inside the container
- **AND** `echo $GH_TOKEN` inside the container is empty
- **AND** `gh auth status` inside the container reports "not logged in"

#### Scenario: --aws grants scoped AWS access

- **GIVEN** the host has completed `aws sso login --profile X` and exports `AWS_PROFILE=X`
- **WHEN** user runs `claude-docker --aws ~/repo`
- **THEN** `aws sts get-caller-identity` inside the container returns the host's identity
- **AND** `~/.aws/credentials` is not present inside the container
- **AND** writes to `/root/.aws/` from inside the container fail with EROFS

#### Scenario: --glab grants read-only token access

- **GIVEN** the host has a valid `~/.config/glab-cli/config.yml`
- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** `glab auth status` reports "logged in" without prompting
- **AND** writes to `/root/.config/glab-cli/` from inside the container fail with EROFS

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

### Requirement: In-container gh login persists only under --gh

Because macOS `gh` uses the Keychain (no host file to mount), the container SHALL support a fresh `gh auth login` whose resulting `~/.config/gh/` persists across runs via the existing `claude-code-root` volume. Access to that persisted state SHALL be gated on the current run actually needing it: `/root/.config/gh/` inside the container MUST appear empty (achieved by overlaying a tmpfs mask) unless the run is `--gh` with no host token found (in-container login is the remaining auth path) or `--gh-direct`. In particular, the mask SHALL stay ON when the auth proxy sidecar is active — the placeholder env token makes persisted login state unnecessary, and leaving it accessible would reintroduce a persisted in-container secret. When `--gh` is absent entirely, the mask applies as before. The same masking rule SHALL apply to `/root/.config/glab-cli/` when `--glab` is not set.

#### Scenario: gh login survives container exit under --gh without a host token

- **GIVEN** the host has no GitHub token (no env vars, `gh auth token` fails)
- **AND** user completes `gh auth login` inside a container launched with `--gh`
- **WHEN** they exit and relaunch with `--gh` (host still has no token)
- **THEN** `gh auth status` reports "logged in" without re-prompting

#### Scenario: persisted gh login is masked while the sidecar is active

- **GIVEN** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **AND** the host has a GitHub token so the sidecar starts
- **WHEN** user runs `claude-docker --gh ~/repo`
- **THEN** `/root/.config/gh/` inside the agent container is empty
- **AND** GitHub access works via the sidecar placeholder token

#### Scenario: prior gh login is hidden without --gh

- **GIVEN** a prior container run completed `gh auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo` without `--gh`
- **THEN** `gh auth status` inside the container reports "not logged in"
- **AND** `/root/.config/gh/` inside the container is empty

#### Scenario: prior glab login is hidden without --glab

- **GIVEN** a prior container run completed `glab auth login` (state persisted in `claude-code-root`)
- **WHEN** user runs `claude-docker ~/repo` without `--glab`
- **THEN** `glab auth status` inside the container reports no authenticated host
- **AND** `/root/.config/glab-cli/` inside the container is empty
