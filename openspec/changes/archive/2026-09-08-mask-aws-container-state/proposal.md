## Why

`run.sh` already treats the AWS CLI's credential cache as too sensitive to bring
in from the host. The comment at `run.sh:394-395` says so outright — the scoped
`--aws` mount excludes `~/.aws/credentials` (long-lived access keys) and
`~/.aws/cli/cache` (cached assume-role STS) — and the spec restates it as an
absolute: "`~/.aws/credentials` and `~/.aws/cli/cache/` SHALL NEVER be mounted,
even under `--aws`."

The container's *own* `/root/.aws/` then gets none of that care. It sits on
`claude-code-root`, which is mounted read-write and shared by every session, and
no tmpfs mask covers it. The masking requirement enumerates `/root/.config/gh`,
`/root/.config/glab-cli` and `/root/.terraform.d`; AWS is absent from it, and
`grep -n -- '--tmpfs' run.sh` returns those three paths and nothing else. So the
STS cache an `--aws` session writes persists after that session exits and is
readable by a later session that opted into nothing — the exact boundary the
opt-in model exists to enforce.

Two scenarios in this capability are consequently false as shipped:

- `external-cli-tools/spec.md:53` — with no flags, "`/root/.aws/` does not exist
  inside the container". It exists, and after any `--aws` session it is
  populated.
- `external-cli-tools/spec.md:66` — under `--aws`, "writes to `/root/.aws/` from
  inside the container fail with EROFS". The directory is writable.

The structural cause is that the spec asks for an outcome in one requirement
that no requirement provides a mechanism for. `Credentials opt-in` states the
desired end state for `/root/.aws/`; `In-container gh login persists only under
--gh` is where masking is actually specified, and it was written for the three
CLIs that have an in-container `auth login` flow, so AWS was never added to it.

The EROFS claim appears to be carried over from the `--glab` scenario directly
below it, where the whole config *directory* is bind-mounted `:ro` and the claim
therefore holds by construction. Under `--aws` only `config` (a single file) and
`sso/` are mounted, which leaves the directory itself on the read-write volume.

**Not overstated:** that cache only ever holds short-lived SSO/STS-derived
material — the long-lived `credentials` file was never in the container at all —
so anything found in it is expired shortly after the session that wrote it ends.
This is a break in the opt-in boundary, not a live credential leak. It earns a
change because the fix is two lines and the spec already requires the behaviour.

## What Changes

- `run.sh`, inside the existing `EPHEMERAL=0` mask block: add `--tmpfs
  /root/.aws` when `--aws` is absent, and `--tmpfs /root/.aws/cli/cache` when it
  is present. The first restores the opt-in boundary; the second stops an
  `--aws` session from leaving derived credentials on the volume behind it.
- Correct `/root/.aws/` from "does not exist" to "is empty" in the no-flags
  scenario. A tmpfs mask makes a path exist-but-empty, which is already how the
  `glab-cli` and `terraform.d` lines in that same scenario are worded. Literal
  non-existence is not something a mount can express, so the original wording
  was never satisfiable by the mechanism the rest of the scenario relies on.
- Replace the false EROFS line in the `--aws` scenario with what the mounts
  actually guarantee: writes to the two mounted paths fail EROFS, and the
  credential cache does not survive the session.
- Extend the masking requirement to cover AWS, so the mechanism and the outcome
  live in the same capability.
- Mirror both masks in `smoke/smoke.sh` and assert them in
  `smoke/assert-in-container.sh`.
- Add `tests/test_masks.py`, the first test of any kind over the mask set.
- Document the mask in README's `--aws` row. The `--glab` and `--tfe` rows
  already state their masking behaviour there, so leaving `--aws` silent
  would make it the one flag whose row does not say what it hides.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `external-cli-tools`: `Credentials opt-in` has two scenario assertions
  corrected to match a mechanism that now exists, and gains a requirement that
  the container's own AWS credential cache not persist. `In-container gh login
  persists only under --gh` gains AWS alongside the glab and terraform.d masking
  rules it already carries.

The `In-container gh login persists only under --gh` title is left alone. It
already governs glab and terraform.d, so it is a misnomer before this change and
no more of one after; retitling it would mean a REMOVED plus ADDED pair in the
delta and a rename in the synced spec, for no behavioural gain.

## Testing

The gap needs a test that reads `run.sh`, not another container assertion, and
the reason is worth recording because it explains why the existing smoke suite
never caught it.

`smoke/smoke.sh:256-260` does not invoke `run.sh`. It re-implements the mask
list — its own comment says "mirrors run.sh" — so a mask missing from `run.sh`
cannot fail the smoke suite, because the harness would simply not add it either.
The suite tests the mirror. Separately,
`smoke/assert-in-container.sh` does check that a non-granted opt-in's config
path is absent or empty, but its AWS entry points at `/root/.aws/config`, a file
that is absent without `--aws` whether or not any mask exists, so that assertion
passes vacuously. Both halves of the harness were working as written; neither
could observe this.

`tests/test_masks.py` therefore asserts the mask set against `run.sh` itself,
and additionally that every mask in `run.sh` appears in the smoke mirror, so the
two cannot drift apart again silently.

## Impact

- `run.sh` — two lines in the `EPHEMERAL=0` block.
- `smoke/smoke.sh`, `smoke/assert-in-container.sh` — mirror and assertions.
- `tests/test_masks.py` — new, stdlib only, consistent with the existing unit
  tests so CI's test step needs no install step.
- `README.md` — one sentence in the `--aws` flag row.
- No change to the Dockerfile, the image, `entrypoint.sh`, or any host-side
  mount. Nothing a user has to migrate: the masked cache re-derives from the
  read-only host SSO mount on first use inside an `--aws` session.

## Out of scope

Under `--aws` the host `~/.aws/sso/` bind-mount is conditional on that directory
existing on the host (`run.sh:399`). Where it does not, an in-container `aws sso
login` would cache its token on the persistent volume. That state is still
masked from every non-`--aws` session by the first mask, so the opt-in boundary
this change is about holds either way; what remains is persistence between two
`--aws` sessions, which is inside the trust boundary that flag grants. Naming it
here rather than fixing it, because the conditional-on-host-state pattern shows
up in several places in `run.sh` and deserves one change of its own rather than
a partial fix wedged into this one.
