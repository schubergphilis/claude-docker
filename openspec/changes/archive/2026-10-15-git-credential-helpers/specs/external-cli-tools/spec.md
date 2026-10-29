## ADDED Requirements

### Requirement: Git credential helper per forge host

So that git can fetch and push over HTTPS with the token a forge flag already forwards, `run.sh` SHALL give git a credential helper for each of these flags, scoped to that forge's host:

- `--gh-direct`: `credential.https://github.com.helper` set to `gh auth git-credential`. `--gh` adds none: the sidecar injects auth for `github.com`.
- `--glab`: `credential.https://<host>.helper` set to `glab auth git-credential`, where `<host>` is `GITLAB_HOST` after token discovery (keeping any port), else `gitlab.com`.
- `--az`: `credential.https://<host>.helper` for the host of `AZURE_DEVOPS_ORG_URL`, else `dev.azure.com`, set to a helper that answers `get` with `AZURE_DEVOPS_EXT_PAT` read from the container env when git calls it. The PAT SHALL NOT appear in argv or in the helper string.

Each helper SHALL be scoped to its host so git never offers that token to another host. A `<host>` that is not a plain `host[:port]` (empty, as from `AZURE_DEVOPS_ORG_URL=https://`, or a `*` glob) SHALL get no helper, with a warning on stderr: git matches an empty host against every host. The config SHALL be passed as `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` env, on one list with any other such entries (`safe.directory` on Git Bash), so nothing is written to `~/.gitconfig`. `run.sh` SHALL NOT rewrite SSH remotes.

#### Scenario: HTTPS push works under --glab

- **GIVEN** a workspace whose `origin` is `https://gitlab.example.com/grp/repo.git` and a GitLab token for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab ~/repo` on a fresh volume and runs `git push` inside the container
- **THEN** git authenticates with the forwarded token without a prompt

#### Scenario: A token is not offered to another host

- **GIVEN** `claude-docker --az ~/repo` with `AZURE_DEVOPS_ORG_URL=https://dev.azure.com/org`
- **WHEN** git asks for credentials for `https://other.example.com`
- **THEN** the PAT helper does not answer and the PAT is not sent

#### Scenario: A URL with no usable host gets no helper

- **GIVEN** `claude-docker --az ~/repo` with `AZURE_DEVOPS_ORG_URL=https://`
- **WHEN** git asks for credentials for any host
- **THEN** no credential helper is configured, the PAT is not sent, and `run.sh` warns that `AZURE_DEVOPS_ORG_URL` has no usable host

#### Scenario: No forge flag, no helper

- **WHEN** user runs `claude-docker ~/repo` on a Linux or macOS host
- **THEN** no `GIT_CONFIG_*` env is passed to the container
