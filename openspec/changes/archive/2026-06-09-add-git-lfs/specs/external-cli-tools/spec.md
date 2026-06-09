## ADDED Requirements

### Requirement: git-lfs installed and LFS filters registered

The container image SHALL ship with `git-lfs` on the default PATH so that git
operations on LFS-backed repositories succeed instead of aborting on a missing
filter program. The image SHALL register the LFS filters system-wide at build
time (e.g. `git lfs install --system --skip-repo`) so that LFS smudge/clean
filtering works whether the host kept its filter configuration repo-local — in
which case `run.sh` copies it into the container's `.git/config` overlay — or
only in the host's global `~/.gitconfig`, which the container does NOT inherit
(only `user.name` / `user.email` are forwarded). The `git-lfs` package MAY be
installed unpinned from the distribution archive, consistent with the existing
`git` install.

#### Scenario: git-lfs present on PATH

- **WHEN** the container launches
- **THEN** `git lfs version` succeeds
- **AND** `git config --system --get filter.lfs.process` reports `git-lfs filter-process`

#### Scenario: worktree creation on an LFS repo no longer aborts

- **GIVEN** a mounted repository whose `.git/config` declares the `lfs` filter with `filter.lfs.required = true` (as carried into the container by the existing config overlay)
- **WHEN** a worktree is created inside the container (e.g. `git worktree add .claude/worktrees/feature -b feature`)
- **THEN** the checkout populating the new worktree completes without the `git: 'lfs' is not a git command` / `external filter 'git-lfs filter-process' failed` error
- **AND** the container session starts normally

#### Scenario: LFS filtering works when host config was global-only

- **GIVEN** a repository tracking files via `.gitattributes` with `filter=lfs` whose `filter.lfs.*` definitions existed only in the host's global `~/.gitconfig` (and therefore are not present in the per-repo `.git/config` overlay)
- **WHEN** git inside the container checks out an LFS-tracked file
- **THEN** the system-registered LFS filter is invoked rather than the file being passed through as an unsmudged pointer
