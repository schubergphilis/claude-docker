## Context

The image installs its npm-backed CLIs (`claude-code`, `openspec`, `pnpm`) in one `npm install -g --ignore-scripts` layer, with versions from generated `pins/<tool>.env` fragments. `update_pins.py` owns the list of automated tools. CI derives its `npm audit signatures` list and its runtime version check from that list.

`ccusage` 20.x is a small node launcher (`src/cli.js`) plus one native binary per OS/CPU, shipped as optional dependencies `@ccusage/ccusage-<os>-<arch>`. The package has no install or postinstall script. The launcher resolves the binary with `require.resolve`, runs `chmod 0755` on it if no executable bit is set, and spawns it.

## Goals / Non-Goals

**Goals:**
- `ccusage` is on PATH at a pinned version and runs as the host UID.
- It is covered by the same pin refresh, soak gate, and CI checks as the other npm tools.

**Non-Goals:**
- Reporting host usage. The container's `/root/.claude/projects/` holds container sessions only, and forwarding the host's would expose every host transcript to the container.
- Pinning ccusage's pricing data. `ccusage` fetches model pricing from the network by default and has an `--offline` mode with bundled prices; that is the caller's choice.

## Decisions

### Decision: Install in the shared npm layer

Add `ccusage@${CCUSAGE_VERSION}` to the existing `npm install -g --ignore-scripts` invocation. Same trust model (npm registry and signed `dist.integrity`), same flags, one layer. A separate layer would save a rebuild of the other npm tools on a ccusage bump, but it would duplicate the install incantation.

### Decision: `chmod` the native binary at build time, not rely on the launcher

npm installs the native binary as `0644`. The launcher's first-run `chmod` works when the installing and running users are the same, but the image installs as root and the container runs as the host UID, so the `chmod` fails with `EPERM` and `ccusage` exits with "native binary is not executable". Setting the bit at build time does what the launcher would have done, without running any package code. The path is resolved with `npm root -g` and the build's architecture, and the build then runs `ccusage --version` and compares it with the pin, so a changed package layout fails the build instead of shipping a broken CLI.

Alternative considered: run the launcher once as root during the build so it does its own `chmod`. Rejected: it has the same effect but runs package code at build time, which the `--ignore-scripts` posture avoids where it can.

### Decision: A new `ccusage-cli` capability

This follows the `openspec-cli` precedent: `external-cli-tools` covers auth-bearing CLIs, and a CLI with no credentials gets its own small capability. The capability binds `ccusage` to `version-pin-refresh` and `package-managers` instead of restating their rules.

## Risks / Trade-offs

- [Compromised npm release at the pinned version] → Same exposure as the other npm tools: version-pinned, `--ignore-scripts`, 7-day soak gate, `npm audit signatures` in CI. The native binary is not separately hashed.
- [Single maintainer package] → Accepted for an optional statusline helper. It runs only when a script calls it, with the host UID's permissions and no credentials beyond what the container already has.
- [Network fetch of pricing data at runtime] → `ccusage` fetches a public pricing table unless run with `--offline`. It sends no credentials and no transcript content. It is documented alongside the other runtime network use.
- [Container-only usage numbers] → Documented. A statusline showing spend in the container shows container spend, which is lower than the host's.

## Migration Plan

None. The next image build ships `ccusage`; a host statusline that probes for it starts showing its segment.
