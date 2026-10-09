## 1. Spec

- [x] 1.1 MODIFIED *Pins stored as per-tool lockfile fragments*: npm listed with the npm-backed tools, new scenario
- [x] 1.2 `openspec validate track-npm-pin --strict` passes

## 2. Pin machinery

- [x] 2.1 `Tool("npm", "npm", "npm", "npm --version", …)` in `TOOLS`
- [x] 2.2 `fragment_lines`: `NPM_VERSION`
- [x] 2.3 `pins/npm.env` at 11.19.1 (unchanged version)

## 3. Image

- [x] 3.1 Drop the inline `npm install -g npm@11.19.1` from the apt layer
- [x] 3.2 New layer before the npm-backed CLIs: `COPY pins/npm.env`, install `npm@${NPM_VERSION}`

## 4. Scan acceptances and docs

- [x] 4.1 `.trivyignore`: the three npm-bundled CVEs expire 2026-11-04, with the reason
- [x] 4.2 `docs/security.md`: npm in the list of npm packages pinned by version

## 5. Verification

- [x] 5.1 `update_pins.py --list-tools` lists npm; `--audit` passes for npm@11.19.1
- [x] 5.2 Full unittest suite
