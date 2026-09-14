## 1. Establish what pnpm 12 actually does

- [x] 1.1 Verify the provisioning claim in the image rather than from the changelog: run
  `pnpm dlx node@22 --version` and confirm it reports a Node version the image does not ship
  (image Node is 24.20.0, pinned via NodeSource)
  (spec: *dlx runtime provisioning is documented as its own capability*)
- [x] 1.2 Locate where the fetched runtime is stored (`pnpm cache path` plus pnpm's
  package-manager store) and confirm both paths are under the container home directory, i.e.
  inside the `claude-code-root` named volume, and so survive `docker run --rm`
  (spec: *persistence of provisioned runtimes is documented*)
- [x] 1.3 Check whether upstream documents a refusal switch for this path. Confirm
  `COREPACK_ENABLE_NETWORK=0` governs the native-binary fallback in `bin/pnpm.mjs`, not `dlx`
  provisioning, so it must not be offered as a mitigation for this
  (spec: *dlx runtime provisioning is documented as its own capability*)

## 2. Correct the documentation

- [x] 2.1 Rewrite the `pnpm dlx` clause in `README.md` § Threat model's runtime code-fetch
  bullet: keep the `npx`-equivalence for the package case, add the provisioning case with the
  five names it reaches, state the signature verification that does apply and the version
  pinning that does not, note that no `GOTOOLCHAIN=local` equivalent is documented, and
  contrast the named-volume persistence with `tfenv install`'s non-persistent `/opt` downloads
  (spec: all three bullet scenarios)
- [x] 2.2 Keep the correction inside the existing bullet rather than adding a sixth one, so
  the five primitives stay comparable in one place
  (spec: *README threat model includes runtime-fetch bullet*)

## 3. Validation

- [x] 3.1 `openspec validate document-pnx-runtime-fetch --strict` passes
- [x] 3.2 `python3 -m unittest discover -s tests -p 'test_*.py'` passes — no code change here,
  run as a regression guard only
- [x] 3.3 Confirm the change carries no Dockerfile, pin, or workflow edit: `git diff --stat`
  touches `README.md` and `openspec/` only
- [x] 3.4 Archive and sync main specs, then confirm `openspec/specs/package-managers/spec.md`
  no longer contains the "functionally equivalent to the already-available `npx`" claim as an
  unqualified statement
