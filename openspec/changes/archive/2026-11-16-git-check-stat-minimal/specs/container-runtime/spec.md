## ADDED Requirements

### Requirement: In-container git compares minimal stat data

As root, before the privilege drop, the entrypoint SHALL set `core.checkStat = minimal` in `/etc/gitconfig`, on every host, so git in the container decides whether a file changed from its mtime in whole seconds, its size and its mode only. `run.sh` SHALL NOT pass the setting through `GIT_CONFIG_*` env and SHALL NOT write it to a workspace's `.git/config` or its overlay. A failed write SHALL print a warning and SHALL NOT stop the entrypoint.

#### Scenario: the system scope carries the setting

- **WHEN** the agent runs `git config --system --get-all core.checkStat` in any session
- **THEN** it prints exactly `minimal`

#### Scenario: a rebase on a clean tree does not report local changes

- **GIVEN** a workspace on a Docker Desktop bind mount with a clean working tree
- **WHEN** the agent runs `git rebase --force-rebase HEAD~1`
- **THEN** git does not abort with `Your local changes to the following files would be overwritten`

#### Scenario: the host's git is unaffected

- **GIVEN** a session has started for `~/repo`
- **WHEN** the user runs `git config --get core.checkStat` in `~/repo` on the host
- **THEN** it prints nothing that `claude-docker` wrote

#### Scenario: a failed write does not stop the session

- **GIVEN** the entrypoint cannot write `/etc/gitconfig`
- **WHEN** it sets `core.checkStat`
- **THEN** it prints a warning and the session still starts
