## ADDED Requirements

### Requirement: Scheduled unattended refresh

The refresh SHALL run on a recurring schedule with no operator present, and the
outcome of every run SHALL be reviewable. A scheduled run SHALL invoke the same
refresh tooling an operator invokes, under the same soak-gated selection and
producing the same report, so the unattended actor cannot resolve a pin that an
operator's run would not have resolved. When a run changes one or more `pins/`
fragments, it SHALL propose them as a pull request against the default branch
carrying that run's full report; when a run changes no fragment, it SHALL NOT
open or modify a pull request. At most one such pull request SHALL be open at a
time: a later run SHALL replace the branch and body of the pull request an
earlier run left open rather than opening a second one, because the pins the
earlier run proposed have been superseded by the later resolution. An operator
SHALL additionally be able to trigger a run on demand and, for that run only,
override the soak window and the major-bump policy. A scheduled run SHALL NOT
modify any manual pin; it reports them exactly as an operator run does.

The pull request SHALL be opened such that the repository's own pull-request
checks run on it, since the pin bump it proposes is validated by building the
image, not by reading the diff. Where the available credential cannot trigger
those checks, that limitation SHALL be documented at the point of configuration,
including its effect on mergeability.

#### Scenario: changed pins are proposed as a pull request

- **GIVEN** a scheduled run resolves at least one tool to a version other than
  its committed pin
- **WHEN** the run completes
- **THEN** the changed `pins/` fragments are pushed to the refresh branch
- **AND** a pull request against the default branch carries the run's full
  report, including the manual-pin reminders

#### Scenario: an unchanged run proposes nothing

- **GIVEN** a scheduled run in which every tool is already on its newest soaked
  version
- **WHEN** the run completes
- **THEN** no branch is pushed and no pull request is opened or edited
- **AND** the run reports that no pin changed

#### Scenario: a later run replaces the open pull request

- **GIVEN** a pull request from an earlier refresh is still open
- **WHEN** a later scheduled run resolves a changed set of pins
- **THEN** that same pull request is updated to the later run's pins and report
- **AND** no second pins pull request is opened alongside it

#### Scenario: on-demand run overrides the soak and major-bump policy

- **GIVEN** an operator triggers a refresh on demand with a wider soak window
  and the major-bump policy set to stay within each tool's current major
- **WHEN** the run resolves versions
- **THEN** it applies those overrides for that run only
- **AND** a subsequent scheduled run resolves under the defaults again

#### Scenario: a failed refresh proposes nothing

- **GIVEN** a scheduled run in which the refresh tooling exits non-zero
- **WHEN** the run ends
- **THEN** no branch is pushed and no pull request is opened or edited
- **AND** the run is reported as failed

#### Scenario: manual pins are reported, never rewritten

- **WHEN** a scheduled run completes with changed automated pins
- **THEN** the proposed change contains no edit to a manual pin
- **AND** the pull request body carries the manual-pin reminders for an operator
  to act on separately
