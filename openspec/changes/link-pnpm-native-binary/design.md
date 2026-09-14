## Context

See `proposal.md` § Why for the motivation. The constraints that shape the approach:

- The Dockerfile installs `claude-code`, `openspec` and `pnpm` in a **single**
  `npm install -g --ignore-scripts` invocation, and already carves out exactly one lifecycle
  script afterwards: `node "$(npm root -g)/@anthropic-ai/claude-code/install.cjs"`. The
  comment above it states the contract that carve-out is held to — platform-detect plus file
  copy, no network, no exec, audit-verified, re-read on each bump. A second carve-out inherits
  that contract or it should not exist.
- `--ignore-scripts` is spec'd (`package-managers`: *npm-backed installs preserve
  --ignore-scripts*) and is one of the image's stated build-time hardening properties. It
  cannot move.
- The CI version check derives its tool set, probe argv and version regex from
  `update_pins.py`'s `TOOLS` registry and runs each probe as
  `docker run --rm claude-docker:ci <probe>`. There is no TTY and no stderr assertion, so the
  registry cannot express "and not degraded".
- `ci.yml`'s `docker-build` job builds `platforms: linux/amd64` only. Anything arch-specific
  that must hold on arm64 has to hold by construction, not by CI observation.
- `npm root -g` is used rather than a hardcoded prefix, so a different npm prefix does not
  break the build.

### Measured behaviour of pnpm 12.3.4

Reproduced on arm64 in a throwaway prefix
(`npm install -g --ignore-scripts --prefix ./probe pnpm@12.3.4`):

| | after install, before `install.js` | after `node install.js` |
| --- | --- | --- |
| `lib/node_modules/pnpm/pnpm` | 1643-byte `sh` script, nlink 1 | 36,109,944 bytes, nlink 2, mode 755 |
| first four bytes | `# p` (a comment) | `7f 45 4c 46` |
| `pnpm --version`, no TTY | `12.3.4`, exit 0, **empty stderr** | `12.3.4`, exit 0 |
| `pnpm --version`, TTY on fd 2 | two-line nag, then `12.3.4` | `12.3.4` |
| `package.json#bin` | four extensionless names | unchanged |

Two facts that matter for the implementation and are easy to get wrong:

- **The native binary *is* installed under `--ignore-scripts`**, but at
  `pnpm/node_modules/@pnpm/exe.linux-<arch>/pnpm` — *nested*, not in the global
  `node_modules/@pnpm/`. It arrives because it is an `optionalDependencies` entry filtered by
  `os`/`cpu`/`libc`, which is dependency resolution, not a script product. Looking for it at
  the top level suggests, wrongly, that the bump is impossible.
- **`install.js` branches on `npm_lifecycle_event`.** Under `postinstall` it only calls
  `relinkNpmWindowsShims()`; otherwise it calls `setup()`, which is the part that links the
  binary. A manual `node install.js` has no `npm_lifecycle_event` in the environment and
  therefore takes the `setup()` path — the one we want. Invoking it by hand is a complete run,
  not a partial one.
- `package.json#bin` keeps all four names pointing at extensionless paths, so npm's existing
  global symlinks stay valid across the rewrite. No relinking is needed on Linux.
- **Only `pnpm` is the native binary.** `pn`, `pnpx` and `pnx` are committed two-line
  `#!/bin/sh` scripts (`exec pnpm "$@"`, `exec pnpm dlx "$@"`), so they dispatch through
  whatever `pnpm` **PATH** resolves to rather than through a sibling path. The image has
  exactly one `pnpm` on PATH, so this is correct there; it is recorded because it means the
  assertion on `bin.pnpm` covers all four bins, and because testing an alias outside the image
  can silently exercise a different pnpm.

## Goals / Non-Goals

**Goals:**

- `pnpm` in the image runs its native binary directly — no Node hop, no nag, on both
  architectures.
- A build that would ship the degraded state **fails**, rather than passing a probe that
  cannot tell the difference.
- `--ignore-scripts` keeps covering every package and transitive dependency; the set of
  scripts the build runs by hand stays enumerable and reviewable.

**Non-Goals:**

- Detecting degraded mode *at runtime* or in the smoke test. Once the build cannot produce it,
  a runtime check is redundant; and the only runtime signal is a TTY-gated human-readable
  string that upstream is free to reword.
- Verifying the native binary's own integrity beyond what npm already does. It arrives inside
  an `@pnpm/exe.linux-*` tarball whose `dist.integrity` npm checks, in the same registry-
  integrity model as the other three npm tools (`npm audit signatures` in CI covers
  provenance). This change does not introduce a sha256 pin for it.
- Reworking how npm tools are pinned. `pins/pnpm.env` stays version-only, like the other npm
  pins.

## Decisions

### Run upstream's `install.js` rather than reimplementing the link

**Alternatives considered:**

- **`cp`/`ln` the binary from the nested `@pnpm/exe.linux-*` in the Dockerfile.** Rejected as
  the more complex choice, not the stricter one. `native-binary.mjs` resolves four Linux
  targets (`linux-x64`, `linux-arm64` and a `-musl` variant of each) and selects among them
  with `detectLinuxLibc()`, which reads
  `process.report.getReport().header.glibcVersionRuntime`. A shell reimplementation would have
  to duplicate that selection logic and would drift from it silently on any upstream change.
- **Drop `--ignore-scripts` for pnpm, or allow-list its build.** Rejected: the flag is a
  boundary for the whole transitive graph, and there is no per-package form of it in
  `npm install -g`. A hand-invoked script is strictly narrower.
- **Corepack.** Moot — and worse here: Corepack runs no lifecycle scripts *and* installs no
  dependencies, so the `@pnpm/exe` package is absent and `bin/pnpm.mjs` reaches its
  **download** path. That is the one configuration that turns a runtime fetch into the normal
  case.
- **Stay on pnpm 11.x.** Moot since 12.3.0, and its failure mode is silent stagnation on a
  major that stops receiving fixes.

The carve-out satisfies the contract the `install.cjs` one is held to, and is **safer** than
it on two counts: `install.js`'s imports are `console`/`child_process`/`fs`/`path`/`process`
only; its single `spawnSync` is inside `relinkNpmWindowsShims()`, which returns immediately
unless `process.platform === 'win32'`; and skipping it degrades rather than breaks, where
skipping `install.cjs` leaves a stub that errors at exec.

### Assert ELF magic at `$(npm root -g)/pnpm/pnpm`

The assertion has to answer one question — *was the placeholder replaced by a native binary?*
— in the build, with no TTY, on either architecture.

**Alternatives considered:**

- **Hard-link count (`nlink == 2`).** Rejected: correct only on the `fs.linkSync` path.
  `install.js` falls back to `fs.copyFileSync` when the link fails (a cross-device layer being
  the obvious case), and a copied binary is perfectly healthy with `nlink == 1`. This
  assertion would fail a good build.
- **File size.** Rejected: changes every release, so it is a pin that nothing maintains.
- **`pnpm --version` and match the version.** Rejected: this is precisely the probe that
  already passes in degraded mode.
- **Allocate a TTY and assert stderr is empty.** Rejected: needs `script`/`unbuffer` in the
  build, and it asserts on a human-readable sentence upstream can reword at will.
- **Assert the `@pnpm/exe.linux-*` directory exists.** Rejected: proves the optional
  dependency resolved, not that the bin was replaced — it would pass on exactly the build we
  are trying to reject.

ELF magic is the direct observation: the placeholder is an `sh` script beginning `# p`, the
native binary begins `\x7fELF`, and that is true of both `linux-x64` and `linux-arm64`
artifacts. `od` is coreutils, already in the base image, so no new build dependency. The check
is four bytes and no `pnpm` execution, which also means it cannot be satisfied by a download
side effect.

### Put the assertion in the same `RUN` as the install

A failed assertion must prevent the layer from being committed at all, and the `npm root -g`
resolution and the pins are already sourced in that shell. A separate `RUN` would cache
independently of the install it is asserting about, which is the wrong coupling: a cached pass
could outlive the install that earned it.

### Carry the bot's generated pins commit rather than regenerate the pins

`pins/*.env` is generated and carries per-artifact sha256 values for the non-npm tools.
Cherry-picking `pins-updater.yml`'s commit (authorship preserved) keeps the generated content
byte-identical and its provenance legible, and avoids a second resolve that could pick
different versions as the soak window slides. `run_audit()` in `ci.yml` re-checks each npm
pin's age against the soak window independently, so the pins are still gated on merge.

## Risks / Trade-offs

- **Verified on arm64 only, locally.** The x64 platform package was not exercised here; the
  selection mechanism is identical but that is an inference. This is mostly mitigated *by the
  change itself*: `ci.yml` builds `linux/amd64`, so the assertion runs on x64 in CI and a
  failed inference is a red build rather than a degraded image.
- **The build now depends on a second upstream script's shape.** `install.js` moving, or the
  placeholder path changing, breaks the build. Accepted deliberately: the alternative is the
  same breakage expressed as a silent degradation. The Dockerfile comment carries the
  re-read-on-each-bump instruction for both scripts.
- **A musl base image would change the selection** (`@pnpm/exe.linux-*-musl`). Not a concern
  for the pinned Ubuntu base, and `install.js` handles it; noted because the rejected
  `cp`/`ln` alternative would not have.
- **Build time and image size.** One extra Node process; the 36 MB binary is hard-linked, not
  duplicated, when `linkSync` succeeds. On the `copyFileSync` fallback the layer carries it
  twice — a size regression, not a correctness one.
