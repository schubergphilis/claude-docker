## Why

pnpm 12 stopped shipping its CLI as a JS bundle. `package.json#bin.pnpm` is now a
shebang-less placeholder that the package's `preinstall`/`postinstall` (`node install.js`)
overwrites with the platform binary from an `@pnpm/exe.linux-*` optional dependency. The
image installs every npm tool with `--ignore-scripts`, so that script never runs.

The first attempt at the bump ([#52](https://github.com/schubergphilis/claude-docker/pull/52))
failed the smoke test on 12.1.0 — the placeholder was prose, and `sh` tried to execute it
(`/usr/bin/pnpm: line 4: syntax error near unexpected token ')'`). The pin was reverted to
`11.23.0` and [#53](https://github.com/schubergphilis/claude-docker/issues/53) opened.

That premise is now obsolete: pnpm **12.3.0** made the placeholder a valid shebang-less `sh`
script that hands over to `bin/pnpm.mjs`, which finds the optional dependency's binary and
spawns it. `npm install -g --ignore-scripts pnpm@12.3.4` followed by `pnpm --version` exits 0
on a clean stdout. So the hold is no longer needed — but a *plain* bump lands the image in a
degraded state, and three properties make that worse than it sounds:

1. **Every `pnpm` invocation pays a Node.js startup hop** before the native binary runs.
2. **Interactive users get a nag on every call.** The placeholder prints "pnpm is running
   through Node.js because the script that installs its native binary was skipped" to stderr,
   gated on `[ -t 2 ]`.
3. **CI cannot detect any of it.** The version check runs
   `docker run --rm claude-docker:ci pnpm --version` with no TTY, and matches the registry's
   `version_re` against stdout. Degraded mode prints exactly `12.3.4` to stdout and writes
   nothing to stderr, so the probe passes. Healthy and degraded are indistinguishable to it by
   construction — the blind spot is in the probe's shape, not in its regex.

There is also a latent fetch path. When `resolveInstalledBinary()` finds nothing,
`bin/pnpm.mjs` **downloads the native binary from `registry.npmjs.org` on first use** (the
`get-pnpm` downloader behind `https://get.pnpm.io`, with npm credentials attached as registry
headers) and caches it next to the wrapper as `pnpm-native`. The image's install does carry
the optional dependency, so that path is not reached today — but nothing in the build asserts
it, and the binary it would fetch is neither pinned nor sha256-verified like every other
downloaded artifact in the image. Linking at build time and failing the build if the link did
not happen closes that on both ends.

Today's scheduled `pins-updater` run already resolved pnpm to 12.3.4, so the pin is moving
regardless; the only open question is whether the image links the binary or ships degraded.

## What Changes

- **Pin pnpm to `12.3.4`.** This change carries the generated refresh commit from
  `pins-updater.yml`'s 2026-09-14 run verbatim (authorship preserved), which moves pnpm plus
  `claude-code`, `openspec`, `uv`, `glab` and `awscli`. The other five are ordinary soaked
  bumps with no code implications; pnpm is the one that needs the Dockerfile work, and #53
  establishes that the two cannot be sequenced apart — pnpm 11.23.0 ships no `install.js`, so
  there is nothing for the build to call until the pin is on 12.x.
- **Invoke pnpm's `install.js` after the `--ignore-scripts` install**, alongside the existing
  `claude-code` `install.cjs` carve-out in the same `RUN`. `--ignore-scripts` itself does not
  move: the carve-out stays an explicit, enumerated list of scripts the build runs by hand
  after reading them, not a relaxation of the flag.
- **Assert at build time that the placeholder was actually replaced** — the highest-value item
  of the three, since it is the only one that closes the blind spot above. The assertion reads
  the first four bytes of `$(npm root -g)/pnpm/pnpm` and fails the build unless they are ELF
  magic (`7f 45 4c 46`). It cannot live in `update_pins.py`'s `--list-tools` registry, which
  carries version probes only.
- **Document `pn` and `pnx`.** pnpm 12 adds two more bins (`pn` → `pnpm`, `pnx` → `pnpm dlx`),
  and npm links all four onto the default PATH. `pnx` is a second name for the `pnpm dlx`
  runtime code-fetch primitive the threat model already covers, so it belongs in that bullet
  and in the bundled-CLIs line rather than being left undocumented.

Not in scope:

- **Relaxing `--ignore-scripts`, or allow-listing pnpm's build under npm.** The flag is a hard
  security boundary for every package and transitive dependency; this change adds one audited
  script invocation to the existing carve-out list, which is the narrower instrument.
- **Placing the `@pnpm/exe.linux-*` binary with a Dockerfile `cp`/`ln`.** Rejected in
  `design.md` as the more complex choice, not the stricter one.
- **A per-tool major-version ceiling in `update_pins.py`.** #53 argues against building it and
  this change removes the motivation: the bump now passes on its own, so there is nothing to
  suppress, and a ceiling's failure mode is silent stagnation on an old major.
- **The manual pins** (`nodejs`, `task`, `go` 1.27.1, the Ubuntu base digest) that the refresh
  report flags under `⚠ needs your eyes`. Separate commits, as the report says.
- **Why the weekly pins PR arrives with no CI** (`PINS_UPDATER_TOKEN` is unset, so a
  `GITHUB_TOKEN`-authored PR never triggers `pull_request`). Real, documented in
  `pins-updater.yml`, and orthogonal to this change.

## Capabilities

### Modified Capabilities

- `package-managers`: the `--ignore-scripts` requirement gains an explicit contract for the
  build's hand-invoked install scripts; a new requirement makes a missing native-binary link a
  build failure; the PATH and threat-model requirements pick up `pn`/`pnx`.

### New Capabilities

None.

## Impact

- `pins/pnpm.env` — `11.23.0` → `12.3.4` (plus the five other pins in the same generated
  commit).
- `Dockerfile` — one `node install.js` invocation and one ELF-magic assertion in the existing
  npm `RUN`; the comment above it now covers a second upstream script, extending the
  re-read-on-each-bump discipline it already states.
- `README.md` — `pn`/`pnx` in the bundled-CLIs line and in the Threat model's runtime
  code-fetch bullet.
- Build-time cost: one extra Node.js process and a 36 MB hard link (a `copyFileSync` fallback
  if the link fails), inside the layer that already runs `npm install -g`.
- New failure mode introduced: a future pnpm release that reorganises `install.js` or its
  placeholder path fails the build loudly at the assertion. That is the intended trade against
  today's silent degradation.
