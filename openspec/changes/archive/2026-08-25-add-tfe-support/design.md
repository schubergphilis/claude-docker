## Context

claude-docker today bundles `gh`, `glab`, and the AWS CLI v2, each gated behind
an explicit `--gh` / `--glab` / `--aws` opt-in that controls credential mounts,
env-var forwarding, and tmpfs masking of in-container persisted auth state. No
equivalent path exists for Terraform Cloud.

Two real workflows are blocked:

1. Inspecting TFC plan output for a PR-triggered run — Claude has no
   authenticated session against `app.terraform.io`.
2. Running `terraform plan/apply` against a TFC-backed workspace from inside
   the container — the image ships no `terraform` binary today, and the binary
   that *would* work is project-pinned (`required_version` /
   `.terraform-version`).

The credentials and the binary are independent problems. The proposal handles
them independently: a credential opt-in for TFC, and a runtime version manager
for terraform itself.

## Goals / Non-Goals

**Goals:**

- Authenticated `app.terraform.io` access from inside the container, opt-in,
  matching the existing credential-flag pattern in `run.sh`.
- A path to obtain a project-pinned `terraform` binary on demand without baking
  any specific version into the image.
- No regression in the default (no-flag) security posture: a user who does not
  pass `--tfe` must not inherit TFC credentials from a prior session.
- Threat model stays explicit: any new runtime code-fetch primitive is
  documented in the same class as `pnpm dlx` / `uvx`.

**Non-Goals:**

- Self-hosted Terraform Enterprise hostnames. The credentials file format
  supports them, but only `app.terraform.io` is wired up now.
- Sentinel policy tooling, `tfc-cli`, community wrappers.
- Automatic VCS-run polling or any TFC-aware orchestration.
- Pinning terraform binary versions in the image. That is the project's job.
- Provider plugin caching (`~/.terraform.d/plugin-cache`). Plugins are
  per-project; out of scope here.

## Decisions

### D1: Opt-in `--tfe` flag, not always-on

Mirrors `--aws` / `--gh` / `--glab`: no flag → no TFC credentials reach the
container. Default-deny is the project's posture for every credential surface;
TFC is not special.

**Alternatives considered:** Always mount `~/.terraform.d/credentials.tfrc.json`
when present. Rejected — silently shipping tokens into a sandbox the user did
not ask to grant them to violates the explicit-consent model and would be the
only credential surface that behaves this way.

### D2: Mount the credentials file, *and* forward `TF_TOKEN_app_terraform_io`

The terraform CLI discovers credentials in two ways: the JSON credentials file
written by `terraform login`, and `TF_TOKEN_<host>` environment variables.
Real users use both — `terraform login` for interactive workstations,
`TF_TOKEN_*` for CI/scripted contexts. Supporting only one would force users
to change their host workflow to use the container.

The mount is read-only. Same posture as `~/.aws/config` and `glab-cli`: the
container should not be able to mutate host credential state.

**Alternatives considered:**
- *Env-var only.* Rejected — breaks the standard `terraform login` UX.
- *Mount whole `~/.terraform.d/`.* Rejected — that directory also holds
  plugin caches and CLI config that aren't credentials and would couple the
  mount surface to unrelated terraform internals.

### D3: tmpfs mask `/root/.terraform.d/` when `--tfe` is off

The `claude-code-root` named volume persists `/root` across sessions. Without
masking, a prior in-container `terraform login` would leave a token at
`/root/.terraform.d/credentials.tfrc.json` that a later session — one that did
*not* pass `--tfe` — would silently inherit. This is the exact leak path the
existing `--gh` / `--glab` tmpfs masks already close.

The mask only applies when `EPHEMERAL=0` (the named volumes are in play). With
`--ephemeral` there is nothing persisted to mask.

**Alternatives considered:** Wipe `/root/.terraform.d/` at container start.
Rejected — destructive, racy, and inconsistent with how the gh/glab masks
already work.

### D4: Ship `tfenv`, not a `terraform` binary

Terraform versions are project-pinned through `required_version` constraints
and `.terraform-version` files. A single bundled terraform version drifts
against real workspaces the moment any project upgrades. `tfenv` reads
`.terraform-version` and fetches the pinned binary on demand, which keeps the
image neutral on version policy.

**Alternatives considered:**
- *Bundle the latest terraform.* Rejected — guaranteed to mismatch the moment
  a workspace pins an older version, and HashiCorp's BSL relicensing makes
  "latest" a moving target with non-trivial license implications.
- *Bundle several pinned versions.* Rejected — combinatorial; no version set
  satisfies every consumer; image bloat.
- *`asdf` / `mise`.* Rejected — heavier, multi-language tools whose surface
  area is much wider than what this change needs. `tfenv` is a single bash
  script, ~25KB, MIT-licensed, single-purpose.

### D5: Pin `tfenv` itself; do *not* pin the terraform binaries it fetches

`tfenv` is a build-time dependency of the image and follows the same
"version pinned + sha256-verified" rule as `gh`, `glab`, the AWS CLI, and `uv`.

The terraform binaries `tfenv install` downloads at runtime are deliberately
*not* pinned by the image. They're version-selected by the user's project
(`.terraform-version`), and pinning them in the image would defeat the entire
reason `tfenv` is here. This is a conscious carve-out from the image's
"everything pinned" rule and must be documented in the threat model.

### D6: Document `tfenv install` in the existing runtime-fetch class

`pnpm dlx` and `uvx` already exist in the image as primitives that fetch and
execute arbitrary code at runtime, and the README's threat model already calls
this out. `tfenv install` is the same class of primitive — pulls a signed
binary from `releases.hashicorp.com` and runs it — and the documentation
needs to say so explicitly so users aren't surprised by a third runtime
network-egress vector.

The trust anchor is `releases.hashicorp.com` over TLS via the system CA bundle.
HashiCorp publishes GPG-signed `SHA256SUMS`; tfenv verifies the SHA but does
*not* verify the GPG signature by default. Documented as-is; not in scope to
re-implement signature verification on top.

## Risks / Trade-offs

- **Risk:** The mounted credentials file may contain tokens for hosts beyond
  `app.terraform.io` (the format is per-host).
  → **Mitigation:** Document scope in README. Per-host filtering is a future
  enhancement; the current change targets app.terraform.io but does not
  block other hosts a user has already authenticated to. Users who need
  isolation can use a credentials file scoped only to TFC.

- **Risk:** `TF_TOKEN_app_terraform_io` is just one member of the
  `TF_TOKEN_<host>` family; users with multi-host setups may expect more.
  → **Mitigation:** Forward only the targeted host's token now; expanding to
  a list (or a glob) is additive later. Out of scope flagged in proposal.

- **Risk:** `tfenv install` caches terraform binaries under
  `$TFENV_ROOT/versions/` (i.e. `/opt/tfenv/versions/`). `/opt` is not
  covered by the `claude-code-root` named volume, so installed terraform
  versions are part of the container's writable layer and are discarded
  on `docker run --rm` exit — every session re-downloads. (We deliberately
  do *not* install tfenv under `/root` to escape this: anything baked
  under `/root` in the image gets frozen by the named volume the first
  time a user runs the image, so future image-level upgrades to tfenv
  itself wouldn't propagate. The upgrade-cleanliness win outweighs the
  per-session download cost.)
  → **Mitigation:** Document in README that terraform downloads do not
  persist across sessions. Power users who want persistence can build
  a child image (`FROM claude-code:local`) that runs
  `tfenv install <version>` at build time, baking the version into a
  derived image.

- **Risk:** Runtime-fetched terraform binary is arbitrary code with no
  build-time SHA pin in this image.
  → **Mitigation:** Documented in threat model alongside `pnpm dlx` / `uvx`.
  Trust anchor is `releases.hashicorp.com` + TLS. Users who need stricter
  posture can pre-stage a vetted terraform binary on the host and PATH-mount
  it; not built in.

- **Trade-off:** Two credential surfaces (file + env var) double the matrix
  of "where did this token come from" debug paths.
  → **Mitigation:** README documents precedence (terraform CLI default:
  env var > file). No code in `run.sh` arbitrates between them — both are
  forwarded; terraform decides.

## Migration Plan

Purely additive. No existing flag behavior changes. No image entrypoint
changes. Rollback is removing the `--tfe` branch from `run.sh` and the
`tfenv` install block from the Dockerfile — both are localized and side-effect
free outside their own opt-in path.

## Open Questions

- Should `--tfe` also mount `~/.terraformrc` (the CLI config file, distinct
  from credentials.tfrc.json)? Current answer: no — out of scope, can be
  added later if a real workflow requires it.
- Long-term: should the flag be renamed `--tfc` to reflect that
  `app.terraform.io` is HCP Terraform / Terraform Cloud, with `--tfe`
  reserved for self-hosted Terraform Enterprise once that lands? Naming-only
  question; defer until self-hosted is actually scoped.
