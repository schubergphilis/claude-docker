## 1. Pin

- [x] 1.1 Carry `pins-updater.yml`'s 2026-09-14 refresh commit onto this branch with its
  authorship intact (`git cherry-pick`), rather than re-running `update_pins.py`: the
  generated content and the non-npm tools' sha256 values stay byte-identical, and a second
  resolve could select different versions as the soak window slides. Verify `pins/pnpm.env`
  reads `12.3.4` and that the other five pins in the commit are unmodified
  (spec: *build links the native binary over the placeholder*)

## 2. Dockerfile — link the binary and assert it

- [x] 2.1 After the existing `claude-code` `install.cjs` line in the same `RUN`, invoke
  `node "$(npm root -g)/pnpm/install.js"`. Keep it inside that `RUN` so it shares the shell
  that already sourced the pins and resolved `npm root -g`, and so a failure prevents the
  layer from being committed. Verify the invocation takes the `setup()` path, not the
  Windows-shim path: `install.js` branches on `npm_lifecycle_event`, which is unset outside
  npm (spec: *build links the native binary over the placeholder*)
- [x] 2.2 Assert in the same `RUN`, immediately after, that the first four bytes of
  `$(npm root -g)/pnpm/pnpm` are ELF magic (`7f454c46`), failing the build otherwise with a
  message naming the degraded state. Use `od` (coreutils, already present) — not `file`, which
  the base image does not ship. Do not assert on hard-link count: `install.js` falls back to
  `copyFileSync` when `linkSync` fails, and a copied binary is healthy with `nlink == 1`
  (spec: *build fails when the placeholder was not replaced*, *no native binary is fetched at
  runtime*)
- [x] 2.3 Extend the comment above the npm layer to cover the second script: state what
  `install.js` does (links the platform binary from the `@pnpm/exe.linux-*` optional
  dependency over the shebang-less placeholder), that its only `spawnSync` is `win32`-gated,
  why skipping it degrades rather than breaks, and that both carve-out scripts are re-read on
  each bump. State why the assertion exists — that `pnpm --version` passes either way and the
  degraded-mode warning is TTY-gated, so CI's version probe cannot see it
  (spec: *hand-invoked install scripts are enumerated, not a blanket exception*)
- [x] 2.4 Confirm no separate `npm install` invocation without `--ignore-scripts` was
  introduced, and that the flag still covers all three npm tools in one invocation
  (spec: *pnpm shares the existing --ignore-scripts invocation*)

## 3. Documentation

- [x] 3.1 Do **not** add `pn`/`pnx` to the preinstalled-CLI line at the top of `README.md`:
  that line lists one entry per tool and already omits `uvx` and `pnpx`, so four alias bins
  would be inconsistent with how the existing aliases are treated. Instead correct the
  scenario, which claimed the line enumerates `uvx` and `pnpx` — it never has — to state the
  rule the README actually follows: one entry per tool, aliases documented under the command
  they alias. Pre-existing spec drift, fixed here because this change has to restate that
  requirement anyway (spec: *bundled CLIs list includes new tools*)
- [x] 3.2 Name `pnpx`/`pnx` as aliases of `pnpm dlx` in the Threat model's runtime code-fetch
  bullet, so the new bins do not read as separate undocumented commands
  (spec: *README threat model includes runtime-fetch bullet*)

## 4. Validation

- [x] 4.1 `openspec validate link-pnpm-native-binary --strict` passes
- [x] 4.2 `python3 -m unittest discover -s tests -p 'test_*.py'` passes (no pin-tooling change
  here, but the pins moved)
- [x] 4.3 Verify the install-then-link sequence against the real 12.3.4 package outside the
  image, since `docker` is not available in this environment: install into a throwaway npm
  prefix with `--ignore-scripts`, confirm the placeholder is a non-ELF `sh` script and that
  `pnpm --version` still exits 0 with empty stderr (the blind spot), then run `install.js` and
  confirm the path becomes ELF and the TTY warning disappears
  (spec: *interactive use carries no degraded-mode warning*)
- [x] 4.4 Leave the `docker build` + smoke matrix to CI, which is also what exercises the
  assertion on `linux/amd64` — the local verification above was done on arm64 only

## 5. Close-out

- [x] 5.1 Note on [#53](https://github.com/schubergphilis/claude-docker/issues/53) which of
  its residual items this change lands, and that its rejected alternatives (major-version
  ceiling, hand-placing the binary) stay rejected with the reasons recorded in `design.md`
- [x] 5.2 Close [#67](https://github.com/schubergphilis/claude-docker/pull/67) with a pointer
  to this PR, stating that its pins are carried here unmodified and that it was superseded
  because the pnpm bump it proposed needed the Dockerfile work to not ship degraded
