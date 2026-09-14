## Why

Both the threat model and its spec requirement claim that `pnpm dlx` is a re-run of a
primitive the image already had:

> The documentation SHALL distinguish `uvx` (PyPI execution) and `tfenv install` (…) from
> `pnpm dlx` (**functionally equivalent to the already-available `npx`**).

That was true through pnpm 11. It stopped being true in pnpm 12, which #68 pinned
(`11.23.0` → `12.3.4`). Naming a package manager or a runtime in `dlx` now provisions the real
thing instead of installing the npm package that shares the name. Measured in the built image:

```
$ pnpm dlx node@22 --version
v22.23.2          # fetched and executed in 3s
```

`pnx deno@2`, `pnx bun@1.3.0`, `pnx yarn@4` and `pnx npm@11` are the same mechanism. So the
image — which deliberately ships no language runtimes beyond one pinned Node and one pinned Go
("other language runtimes are not: `tfenv` and `uv` fetch your project-pinned Terraform /
Python on demand") — now has a one-command path to fetching and executing a *different*,
image-unpinned Node, Deno or Bun. Under `--yolo`, a prompt-injected workspace can reach it,
and the version can be selected by the workspace itself through `devEngines.runtime` or
`packageManager`.

Two properties make this worth writing down rather than filing as a curiosity:

- **It is the `tfenv install` shape, not the `npx` shape.** The threat model already treats
  "fetches an unpinned binary whose version the workspace selects" as its own category, with
  `tfenv install` as the example. This belongs in that category, and the documentation
  currently says the opposite.
- **What it downloads persists.** `tfenv install` writes to `/opt/tfenv/versions/`, which the
  README notes does *not* survive `docker run --rm`. Provisioned runtimes land in
  `~/.local/share/pnpm/package-manager-store` and `~/.cache/pnpm` — inside the
  `claude-code-root` named volume — so they persist across container exits and are reused by
  later sessions. A fetched runtime is therefore longer-lived than a fetched terraform.

The honest mitigation belongs in the same sentence: pnpm resolves these through npm's trusted
package-manager registries and verifies an npm-published one against npm's signature for its
exact version before executing it. Provenance is checked; what the image gives up is version
pinning, exactly as with `tfenv install`.

## What Changes

- **Correct the threat model bullet in `README.md`.** Keep the accurate half — `dlx` running a
  *package* really is `npx`-equivalent — and add what pnpm 12 added: the runtime and
  package-manager provisioning, the four names it is reachable under, the signature
  verification that does apply, the absence of a documented refusal switch of the
  `GOTOOLCHAIN=local` kind, and the named-volume persistence that distinguishes it from
  `tfenv install`.
- **Correct the `package-managers` requirement** that mandates the bullet, so the spec stops
  requiring the claim it currently requires, and gains scenarios for the provisioning and the
  persistence.

Not in scope:

- **Blocking or restricting the capability.** pnpm exposes no documented equivalent of
  `GOTOOLCHAIN=local` for this, and the image's position on the other runtime-fetch primitives
  (`npx`, `uvx`, `tfenv install`, the Go toolchain download) is to document them, not to fence
  them — `--yolo` is where that trade-off is already made. Fencing one of five would be a
  posture change, and belongs in its own change with its own argument.
- **Pinning a runtime for `dlx` to prefer**, or setting `devEngines.runtime` anywhere in the
  image. That is workspace policy, not image policy.
- **`minimumReleaseAge`.** pnpm 12 also ships a release-age cooldown, verified at install time
  against the lockfile — the mechanism [#53](https://github.com/schubergphilis/claude-docker/issues/53)
  deferred as a separate discussion about npm/pnpm supply-chain posture. Still separate, and
  now actually available to configure; worth its own change rather than riding along here.
- **The `pnpm dlx works as an npx replacement` requirement.** It describes running a package
  from the registry, which pnpm 12 does not change.

## Capabilities

### Modified Capabilities

- `package-managers`: the runtime code-fetch threat-model requirement stops asserting that
  `pnpm dlx` is `npx`-equivalent and starts requiring the provisioning behaviour, its
  provenance check, and its persistence to be documented.

### New Capabilities

None.

## Impact

- `README.md` — the Threat model § runtime code-fetch bullet.
- `openspec/specs/package-managers/spec.md` — via the delta.
- No behaviour change, no Dockerfile change, no new pin. Documentation catching up with a
  capability the merged pnpm 12 bump already shipped.
