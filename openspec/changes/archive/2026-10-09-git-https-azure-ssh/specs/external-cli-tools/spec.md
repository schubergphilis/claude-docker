## MODIFIED Requirements

### Requirement: Git over HTTPS opt-in

`run.sh` SHALL accept a `--git-https` flag that makes git and glab use HTTPS with the forwarded token instead of SSH, for whichever of `--gh`, `--gh-direct`, `--glab` and `--az` are also passed. Without `--git-https`, `run.sh` SHALL NOT add any of the git config or env below.

- With `--gh` or `--gh-direct`: rewrite `git@github.com:` and `ssh://git@github.com/` to `https://github.com/` via `url.https://github.com/.insteadOf`. With `--gh-direct`, set `credential.https://github.com.helper` to `gh auth git-credential`; under `--gh` the sidecar supplies auth.
- With `--glab`: for the GitLab host (`GITLAB_HOST` after token discovery, else `gitlab.com`, keeping any port in the HTTPS URL), rewrite `git@<host>:` and `ssh://git@<host>/` to `https://<host>/`, set `credential.https://<host>.helper` to `glab auth git-credential`, and forward `GLAB_GIT_PROTOCOL=https`.
- With `--az`: for the host of `AZURE_DEVOPS_ORG_URL` (else `dev.azure.com`), set a credential helper that answers `get` with `AZURE_DEVOPS_EXT_PAT` read from the container env at call time; the PAT SHALL NOT appear in argv or in the helper string. For each workspace remote (any `remote.<name>.url` of a workspace's common git config) on that host, also rewrite its SSH prefix: for Services (host `dev.azure.com`), `git@ssh.dev.azure.com:v3/<org>/<project>/` and `ssh://git@ssh.dev.azure.com/v3/<org>/<project>/` to `https://dev.azure.com/<org>/<project>/_git/`; for Server (an `AZURE_DEVOPS_ORG_URL` ending in the collection), the `ssh://` prefix up to and including `/<collection>/` to `AZURE_DEVOPS_ORG_URL/`. SSH remotes of other hosts SHALL NOT be rewritten.
- The config SHALL be passed as `GIT_CONFIG_COUNT` / `GIT_CONFIG_KEY_<n>` / `GIT_CONFIG_VALUE_<n>` env, together with any other such entries (`safe.directory` on Git Bash), so nothing is written to `~/.gitconfig`.
- `--git-https` without any of `--gh`, `--gh-direct`, `--glab`, `--az` SHALL print a one-line warning to stderr and continue.

#### Scenario: GitLab SSH remote goes over HTTPS

- **GIVEN** a workspace whose `origin` is `git@gitlab.example.com:grp/repo.git` and a GitLab token for `gitlab.example.com`
- **WHEN** user runs `claude-docker --glab --git-https ~/repo`
- **THEN** `git ls-remote --get-url origin` inside the container prints `https://gitlab.example.com/grp/repo.git`
- **AND** `git fetch` authenticates with `GITLAB_TOKEN` without a prompt
- **AND** `glab config get git_protocol` prints `https`

#### Scenario: No flag, no change

- **WHEN** user runs `claude-docker --glab ~/repo`
- **THEN** no `GIT_CONFIG_*` or `GLAB_GIT_PROTOCOL` env is passed to the container on Linux and macOS hosts

#### Scenario: Azure DevOps Server SSH remote goes over HTTPS

- **GIVEN** `AZURE_DEVOPS_ORG_URL=https://ado.example.com/tfs/Coll` and a workspace whose `origin` is `ssh://ado.example.com:22/tfs/Coll/Proj/_git/repo`
- **WHEN** user runs `claude-docker --az --git-https ~/repo`
- **THEN** `git ls-remote --get-url origin` inside the container prints `https://ado.example.com/tfs/Coll/Proj/_git/repo`
- **AND** `git fetch` authenticates with `AZURE_DEVOPS_EXT_PAT` without a prompt

#### Scenario: Azure DevOps Services SSH remote goes over HTTPS

- **GIVEN** `AZURE_DEVOPS_ORG_URL=https://dev.azure.com/org` and a workspace whose `origin` is `git@ssh.dev.azure.com:v3/org/proj/repo`
- **WHEN** user runs `claude-docker --az --git-https ~/repo`
- **THEN** `git ls-remote --get-url git@ssh.dev.azure.com:v3/org/proj/other` inside the container prints `https://dev.azure.com/org/proj/_git/other`
