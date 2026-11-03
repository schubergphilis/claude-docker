## ADDED Requirements

### Requirement: Pull request titles are Conventional Commits

Every pull request title SHALL be checked against Conventional Commits when the pull request
is opened, reopened, pushed to, or edited, with the types commitlint enforces on the commits.
A scope SHALL stay optional, and `!` SHALL mark a breaking change. Any other title SHALL fail
the check, and the title SHALL reach the check as data, never as code.

#### Scenario: a Conventional Commit title passes

- **GIVEN** a pull request titled `feat(run): add a flag`
- **WHEN** the check runs
- **THEN** it passes

#### Scenario: a breaking-change title passes

- **GIVEN** a pull request titled `feat!: drop the old flag`
- **WHEN** the check runs
- **THEN** it passes

#### Scenario: a title without a type fails

- **GIVEN** a pull request titled `Fix typo`
- **WHEN** the check runs
- **THEN** it fails and names the expected format and the allowed types

#### Scenario: a corrected title is checked again

- **GIVEN** a pull request whose title check failed
- **WHEN** its title is edited into a Conventional Commit, with no new push
- **THEN** the check runs again and passes

#### Scenario: a title cannot run as code

- **GIVEN** a pull request titled `` feat: $(touch pwned) `x` ``
- **WHEN** the check runs
- **THEN** nothing in the title is executed
