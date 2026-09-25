## MODIFIED Requirements

### Requirement: Soak-aware version resolution

The refresh tooling SHALL, for each automated tool, select the highest stable released version whose publish date is older than that tool's soak window. Each automated tool SHALL carry its own default soak window: 1 day for `claude-code`, 7 days for every other automated tool. An operator MAY pass `--soak` to apply a single window to every tool for that run; without it, each tool's default window SHALL apply. The soak gate that verifies committed pins SHALL apply the same per-tool windows. Prerelease versions SHALL be excluded. By default, selection SHALL include major-version increments (e.g. 10.x → 11.x); the tooling SHALL NOT restrict resolution to the currently-pinned major line. An operator MAY pass `--block-major-bumps` to constrain a run to the currently-pinned major; when set and the newest soaked version crosses the major, the tooling SHALL instead select the newest soaked version within the current major and SHALL report the crossed major as blocked. A newer version that exists but falls inside the soak window SHALL NOT be selected; the current pin SHALL be retained instead.

#### Scenario: major version increment is selected and flagged

- **GIVEN** tool X is pinned at 10.33.2 and version 11.5.3 was published 9 days ago with a soak window of 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the resolved pin for X is 11.5.3
- **AND** the report marks the change as a major bump, visually distinct from minor/patch updates

#### Scenario: major bump suppressed under --block-major-bumps

- **GIVEN** tool X is pinned at 10.33.2, version 10.34.1 was published 15 days ago, and version 11.5.3 was published 9 days ago, with a soak window of 7 days
- **WHEN** the operator runs the refresh script with `--block-major-bumps`
- **THEN** the resolved pin for X is 10.34.1
- **AND** the report shows 11.5.3 as available but blocked by `--block-major-bumps`

#### Scenario: newest soaked version selected

- **GIVEN** tool X has versions 1.2.0 (published 20 days ago) and 1.3.0 (published 10 days ago) and the soak window is 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the resolved pin for X is 1.3.0

#### Scenario: too-new version held back by the soak

- **GIVEN** tool X is pinned at 1.3.0 and a version 1.4.0 was published 3 days ago with a soak window of 7 days
- **WHEN** the operator runs the refresh script
- **THEN** the pin for X remains 1.3.0
- **AND** the report marks X as `held`, naming the in-soak version and its age

#### Scenario: no newer version available

- **GIVEN** the pinned version is already the newest released version
- **WHEN** the operator runs the refresh script
- **THEN** the pin is unchanged and the report shows no update for that tool

#### Scenario: claude-code uses a 1-day window

- **GIVEN** `claude-code` is pinned at 2.1.10 and version 2.1.11 was published 30 hours ago
- **WHEN** the operator runs the refresh script without `--soak`
- **THEN** the resolved pin for `claude-code` is 2.1.11

#### Scenario: other tools keep the 7-day window

- **GIVEN** tool X (not `claude-code`) is pinned at 1.3.0 and version 1.4.0 was published 30 hours ago
- **WHEN** the operator runs the refresh script without `--soak`
- **THEN** the pin for X remains 1.3.0
- **AND** the report marks X as `held`, naming 1.4.0 as the in-soak version

#### Scenario: --soak overrides every tool's window

- **GIVEN** `claude-code` is pinned at 2.1.10 and version 2.1.11 was published 3 days ago
- **WHEN** the operator runs the refresh script with `--soak 7`
- **THEN** the pin for `claude-code` remains 2.1.10
- **AND** the report marks 2.1.11 as `held`
