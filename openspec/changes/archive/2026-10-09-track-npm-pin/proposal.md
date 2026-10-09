## Why

The image replaces the npm NodeSource bundles with `npm@11.19.1`, installed inline in
the apt layer. That pin sits outside the pin machinery: the weekly refresh never bumps
it, CI's version check and `npm audit signatures` never see it, and nothing records
when a fixed npm ships. npm vendors its dependencies, so their CVEs are cleared only
by a newer npm release. Three of them are accepted in `.trivyignore` with an expiry,
and nothing would prompt a bump before it lapses (#51).

## What Changes

- npm becomes an automated npm-kind tool: a `Tool("npm", …)` entry, `pins/npm.env`
  (`NPM_VERSION`), and its own Dockerfile layer that sources the fragment, ahead of
  the npm-backed CLIs. It gets the same soak window, signature audit and runtime
  version check as `claude-code`, `openspec` and `pnpm`, with no CI edit.
- The pin stays at 11.19.1. The refresh selects the highest soaked version, and the
  weekly updater bundles every bump into one PR, so its next run would carry npm 12
  alongside the routine bumps. npm 12 is meant to land as its own reviewed change
  first, so that run finds nothing to propose for npm.
- `.grype.yaml` drops its rule ignoring everything under `node_modules/npm/`: its
  premise (only a Node upgrade moves npm's bundle) no longer holds, and the
  accepted npm CVEs are covered by the expiring `.trivyignore` entries.
- The three npm-bundled CVE acceptances move from 2026-10-21 to 2026-11-04: npm
  11.21.0 and 12.2.0 still bundle the unfixed undici and brace-expansion.

## Capabilities

- `version-pin-refresh`: MODIFIED *Pins stored as per-tool lockfile fragments* (npm
  added to the npm-backed tools) and *Build consumes fragments without hand-authored
  pins* (npm's own layer; the layer-cache scenario covers both npm layers, plus a new
  one for an npm-only bump).

## Impact

- `update_pins.py`, `pins/npm.env`, `Dockerfile`, `.trivyignore`, `.grype.yaml`,
  `docs/security.md`, `docs/auth.md`, `tests/test_update_pins.py`. The image's npm
  version is unchanged.
