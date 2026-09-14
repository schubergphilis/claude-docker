## Context

See `proposal.md` § Why. The constraints that shape the wording:

- The threat model's runtime code-fetch bullet is a single long bullet that already sorts its
  primitives into two groups: ones that add nothing new (`npx`, and — until pnpm 12 — `pnpm
  dlx`) and ones that are a new capability whose downloads the image does not pin (`uvx`,
  `tfenv install`, the Go toolchain download). The correction is a reclassification within an
  existing structure, not a new section.
- The bullet is mandated almost word-for-word by a spec requirement, so the two move together
  or the spec starts requiring a false statement.
- `tfenv install` is the closest existing analogue and the README already says its downloads
  do not persist across `docker run --rm`. That sentence is what makes the persistence
  difference worth stating rather than assumed.
- The Go toolchain paragraph sets the precedent for naming a refusal switch
  (`GOTOOLCHAIN=local`) where upstream provides one.

### Measured behaviour

In the image built from `main` at the pnpm 12.3.4 pin:

| observation | result |
| --- | --- |
| `pnpm dlx node@22 --version` | `v22.23.2`, exit 0, ~3s |
| where it landed | `~/.local/share/pnpm/package-manager-store/` (301 MB after one runtime) |
| metadata / dlx cache | `~/.cache/pnpm/` (`pnpm cache path`) |
| both paths under | `/root`, i.e. the `claude-code-root` named volume — persists across `--rm` |
| image's own Node | 24.20.0, pinned in the Dockerfile via NodeSource; unaffected |

Upstream's description of the fetch path, from pnpm's 12.0.0 changelog: the package managers
and runtimes are "resolved and fetched through the trusted package-manager registries, and an
npm-published one is verified against npm's signature for its exact version before it is
executed."

## Goals / Non-Goals

**Goals:**

- A reader of the threat model learns that `pnx node@22` is possible, what is and is not
  verified about it, and that it leaves state behind in the named volume.
- The spec requirement stops mandating a claim that the shipped image contradicts.
- Keep the accurate part of the existing claim: `dlx` on an ordinary package is still
  `npx`-equivalent, and saying otherwise would overstate the change.

**Non-Goals:**

- Changing what the image allows. See `proposal.md` § Not in scope.
- Enumerating every specifier form pnpm accepts (`pnx yarn@npm:yarn@1.22.22`,
  `pnx --package npm@11 npx …`). The threat model needs the capability and its shape, not the
  CLI surface; upstream's changelog is the reference for the rest.

## Decisions

### Reclassify rather than add a second bullet

The bullet's job is to enumerate runtime code-fetch primitives and say which ones are new.
`pnpm dlx` is already in it, in the wrong group for pnpm 12. Moving it — while keeping the
package case in the old group, because both statements are true of different invocations — is
smaller and keeps all five primitives comparable in one place. A separate bullet would invite
reading it as a sixth, unrelated primitive.

### State the signature verification in the same breath as the risk

The temptation is to describe only the new reach. But the fetch is provenance-checked, and a
threat model that omits that would overstate the exposure and, worse, teach a reader to
discount the document. The precise distinction is **provenance is verified, version is not
pinned by the image** — which is exactly what the bullet already says about `tfenv install`,
so the parallel does the explaining.

### Say that no refusal switch is documented, rather than that none exists

The shipped changelog documents no `GOTOOLCHAIN=local` equivalent for `dlx` provisioning, and
`COREPACK_ENABLE_NETWORK=0` governs a different path (the native-binary fallback in
`bin/pnpm.mjs`, not `dlx`). Absence in the changelog is not proof of absence in the
implementation, so the wording claims the former. If upstream adds or reveals one, the bullet
gains a clause without having to retract a claim.

### Name the persistence, because it changes the lifetime of the fetched code

Every other runtime-fetch primitive in the bullet either writes into a project directory or,
for `tfenv install`, into `/opt`, which the README explicitly says does not survive `--rm`.
This one writes under `/root`, so a runtime fetched once by a `--yolo` session is present for
every later session using that volume. That is the part a reader cannot infer from the rest of
the bullet.

## Risks / Trade-offs

- **The bullet gets longer**, and it is already dense. Accepted: the alternative is a shorter
  sentence that is wrong. The structure it already has (group, then per-primitive
  qualification) absorbs the addition.
- **`pnx` specifier semantics may keep moving.** pnpm 12 changed what a bare name means in
  `dlx`; a later release could change it again. The wording therefore describes the capability
  ("naming a package manager or a runtime provisions the real thing") rather than pinning
  itself to a table of examples that would need maintaining.
- **No test covers this.** Consistent with the rest of the bullet — it is documentation of
  reachable capability, and the repo does not smoke-test `npx`, `uvx` or `tfenv install`
  either. Exercising it in CI would mean downloading a second runtime per build.
