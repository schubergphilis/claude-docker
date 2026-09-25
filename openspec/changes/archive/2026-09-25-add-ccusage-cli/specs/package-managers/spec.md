## MODIFIED Requirements

### Requirement: npm-backed installs preserve --ignore-scripts

Any package installed via `npm install -g` in the image SHALL be installed with `--ignore-scripts` to prevent post-install lifecycle scripts from executing as root at build time. Adding `pnpm` to the existing npm install line SHALL NOT remove or weaken this flag.

Where a tool is unusable without its own install script, the build MAY invoke that one script by hand after the install. Such carve-outs SHALL be individually enumerated in the Dockerfile with the reason each is needed; SHALL be limited to scripts that, on Linux, only detect the platform and move files — no network access and no execution of further code; and SHALL be re-read on each version bump of the tool that owns them. Invoking a script by hand SHALL NOT be used as a substitute for the flag, and SHALL NOT extend to any package's transitive dependencies.

Setting the executable bit on a file a package ships is not a lifecycle script and needs no carve-out, but each such `chmod` SHALL likewise be named in the Dockerfile with the reason it is needed.

#### Scenario: pnpm shares the existing --ignore-scripts invocation

- **WHEN** the Dockerfile installs `pnpm` via npm
- **THEN** the install runs as part of a single `npm install -g --ignore-scripts` invocation alongside `claude-code`, `openspec`, and `ccusage`
- **AND** no separate `npm install` invocation without `--ignore-scripts` exists in the Dockerfile

#### Scenario: hand-invoked install scripts are enumerated, not a blanket exception

- **WHEN** a reader inspects the npm install layer in the Dockerfile
- **THEN** each install script the build runs by hand is named explicitly, with the reason it is required
- **AND** no lifecycle script runs for any package that is not named there, including transitive dependencies
- **AND** the comment states that each named script is re-read when its tool's pin moves
