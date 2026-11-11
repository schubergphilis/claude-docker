## MODIFIED Requirements

### Requirement: Accepted scanner findings are recorded and scoped

Findings that the pipeline suppresses in order to publish SHALL be recorded in version-
controlled configuration, each carrying the reason it was accepted.

A suppression SHALL be scoped by a property that remains true for as long as its reason does —
the package's type or its location within the image — and SHALL NOT be scoped by vulnerability
identifier. An identifier-scoped suppression expires silently when upstream fixes it, and
covers none of the next findings in the same unfixable component.

The one exception is a finding that the image's distribution marks not-affected for every
version of the package it ships: no update will ever clear it, so its identifier is the
property that stays true. Such a suppression SHALL name the vulnerability identifier, the
package and the package type, and SHALL record that the distribution rules it out.

A suppression SHALL NOT extend beyond the component it was accepted for. In particular, a
finding accepted because it lives in a vendored dependency tree SHALL NOT also suppress the
same package where the image installs it in its own right.

#### Scenario: a finding in vendored upstream code is accepted

- **GIVEN** a vulnerability in code vendored inside a prebuilt third-party binary, which no
  change in this repository can fix
- **WHEN** the pipeline scans the image
- **THEN** the finding does not block publication
- **AND** the suppression records the reason it was accepted

#### Scenario: a suppression does not cover a fixable instance

- **GIVEN** a suppression accepted for a component this repository does not control
- **AND** the same class of finding in a component this repository does pin and control
- **WHEN** the pipeline scans the image
- **THEN** the fixable finding is still reported and still blocks publication

#### Scenario: an unrelated vulnerable package stays enforced

- **GIVEN** a vulnerable package outside every recorded suppression's scope
- **WHEN** the pipeline scans the image
- **THEN** it blocks publication

#### Scenario: a finding the distribution rules out is accepted by identifier

- **GIVEN** a finding in a distribution package that the distribution marks not-affected for
  every version it ships
- **WHEN** the pipeline scans the image
- **THEN** a suppression naming that identifier, package and package type keeps it from
  blocking publication
- **AND** the suppression records that the distribution rules it out
- **AND** any other finding in the same package still blocks publication
