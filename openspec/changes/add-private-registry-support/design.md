## Context

`claude-docker` bundles `uv`/`uvx`/`pnpm`/`pnpx` but always resolves against the
public npm registry and PyPI. Teams running a private mirror (AWS CodeArtifact,
Artifactory, Nexus, GitLab/Azure feeds) want the in-container package managers
to resolve the same way their pipelines do.

Both ecosystems already support private registries through their own native
configuration — there is nothing to teach `uv`/`pnpm`, only a host→container
surfacing problem. `run.sh` already solves exactly this shape for other host
credentials (`--aws`/`--gh`/`--glab`/`--tfe`): an opt-in flag that conditionally
adds read-only config mounts and forwards env vars. `--registry` is the same
move applied to package-manager registry config.

## Goals / Non-Goals

**Goals:**

- Make `uv` and `pnpm` resolve against a host-configured private registry from
  inside the container, opt-in, matching the existing credential-flag pattern.
- Stay as faithful as possible to native `uv`/`npm` behaviour — forward the
  tools' own config channels rather than inventing wrapper config.
- No regression in the default (no-flag) posture: a user who does not pass
  `--registry` inherits no registry config and no registry credentials.

**Non-Goals:**

- Inventing `CLAUDE_DOCKER_*` registry variables or any ecosystem translation
  layer.
- A wrapper-enforced lockdown / loosen policy. Resolution policy is expressed
  by the host's native config.
- In-container token minting or refresh (no `aws codeartifact
  get-authorization-token` baked in — the host produces the token; the wrapper
  only forwards the resulting native config).
- Network egress filtering. This is registry-resolution config, not a network
  boundary.
- Registry-specific support code. CodeArtifact, Artifactory, Nexus, etc. all
  speak the npm/PyPI dialect; the agnostic native-config passthrough covers
  them uniformly.

## Decisions

### D1: Opt-in `--registry` flag, not always-on

`~/.npmrc` / `~/.netrc` routinely carry long-lived auth tokens. Mounting them
is the same exposure class as `--gh`/`--glab`, so it must be default-deny and
explicit, consistent with every other credential surface in the wrapper.

**Alternatives considered:** Always mount `~/.npmrc` when present. Rejected —
silently shipping registry tokens into a sandbox the user did not opt into
violates the explicit-consent model and would be the only credential surface
that behaves that way.

### D2: Forward *native* config, not wrapper-invented variables

The most faithful way to get native resolution behaviour is to hand the package
managers the exact inputs they already read on the host:

- npm/pnpm read `~/.npmrc` (registry + `//host/:_authToken`). This is the
  canonical home for npm-side registry config; auth tokens there are keyed by
  host (`//host/:_authToken`), a name containing `/` and `:` that cannot be a
  normal shell variable — which is exactly why the file, not an env var, is the
  npm/pnpm channel.
- uv is env-var-first (`UV_DEFAULT_INDEX` / `UV_INDEX_*`) and also reads
  `~/.netrc` and `~/.config/uv/uv.toml`.

So the wrapper mounts the files read-only and forwards the env vars — nothing
invented, nothing translated. A host that already runs `aws codeartifact login`
(which writes the token into `~/.npmrc`) works with zero extra steps.

**Alternatives considered:** Define `CLAUDE_DOCKER_NPM_REGISTRY` /
`_NPM_TOKEN` / `_PYPI_INDEX` / … and materialise config inside the container.
Rejected — invents a parallel config surface to keep in sync, and diverges from
"behaves like uv/npm do on the host," which was the explicit design goal.

### D3: Both channels — config files *and* env vars

uv and npm/pnpm each discover registry config through more than one channel and
real users use both (files for interactive workstations, env vars for
scripted/CI-flavoured setups). Forwarding only one would force users to change
their host workflow to use the container. Mounts are read-only; the container
must not be able to mutate host registry credentials.

### D4: Enumerate uv's dynamic per-index credential vars

uv's per-index auth vars are `UV_INDEX_<NAME>_USERNAME` /
`UV_INDEX_<NAME>_PASSWORD`, where `<NAME>` is a user-chosen index name. A fixed
forwarding list (the pattern used for `AWS_*` / `TF_TOKEN_app_terraform_io`)
cannot capture them. `run.sh` therefore scans exported host variables
(`compgen -e`) and forwards any matching `UV_INDEX_*_USERNAME` /
`UV_INDEX_*_PASSWORD`.

The scan is scoped to those two suffixes rather than a blanket `UV_*` forward on
purpose: a host `UV_CACHE_DIR=/Users/you/...` (or similar path-valued uv var)
would point at a path that does not exist in the container and break installs.
Only the index/auth-relevant vars are forwarded; the rest of uv's static index
vars are an explicit allow-list (`UV_INDEX_URL`, `UV_DEFAULT_INDEX`,
`UV_EXTRA_INDEX_URL`, `UV_INDEX`, `UV_NETRC`, `UV_KEYRING_PROVIDER`).

### D5: Resolution policy is the host config's job — no wrapper lockdown flag

Setting a default registry (`registry=` in `~/.npmrc`) or default index
(`UV_DEFAULT_INDEX`) natively *replaces* the public default rather than
supplementing it. So a host config that names only a private feed already
confines resolution to that feed — "lockdown" is free and native. Re-admitting
the public registry as an additional index is likewise expressed natively
(extra-index lines). The wrapper therefore needs no `--registry-allow-public`
policy flag; it forwards config and lets the tools decide.

**Consequence to document:** if the private feed has no public upstream
configured (a curated allow-list rather than a proxying mirror), `uvx` /
`pnpm dlx` of tooling that isn't mirrored will fail under that host config —
because the host config locked resolution down, not because the wrapper did.

### D6: No tmpfs masking for `--registry`

`--gh`/`--glab`/`--tfe` mask their persisted state when the flag is off because
those tools support an in-container `login` that writes host-equivalent
credentials into the `claude-code-root` volume, which a later non-opted-in
session would otherwise inherit. `--registry` introduces no such vector:

- The host config files are mounted **read-only**, so a `--registry` session
  cannot persist new registry credentials into the volume.
- Registry config has a host file as its source of truth; the wrapper does not
  need to support a persistent in-container registry login the way `gh` (macOS
  Keychain, no host file) does.

A user who manually runs `npm login` inside a no-flag session is acting on their
own credentials, the same as any other state they write into the persistent
volume — not a host-credential boundary crossing. So there is nothing for a
mask to protect here, and the single-file target (`/root/.npmrc`) does not fit
the directory-oriented `--tmpfs` mechanism the other masks use.

**Revisit if** real usage shows users relying on persisted in-container
`npm login` across no-flag sessions — the likely fix is relocating npm's
`userconfig` off the persisted volume rather than masking a file.

### D7: Token freshness — freeze at launch, refresh by restart

A registry token captured at container start (notably a CodeArtifact token,
≤12h TTL) freezes for the life of the container. This matches the documented
`--aws` SSO-cred behaviour: relaunch when it expires. No in-container refresh
helper in v1.

## Risks / Trade-offs

- **Risk:** `~/.npmrc` / `~/.netrc` may carry tokens for registries beyond the
  one the user has in mind (both files are multi-entry).
  → **Mitigation:** Document the exposure in the opt-in table and threat model;
  read-only mount; default-deny without the flag. Users who want isolation can
  scope their host files. Same trade-off already accepted for `--tfe`'s
  multi-host credentials file.

- **Risk:** A templated `~/.npmrc` (`_authToken=${SOME_VAR}`) needs the
  referenced env var forwarded too; arbitrary names won't be caught by the
  static list.
  → **Mitigation:** Document that literal-token files work out of the box;
  `NODE_AUTH_TOKEN` / `NPM_TOKEN` (the common conventions) are forwarded; other
  names can be exported and the user can extend their own config. Iterate if a
  common name shows up.

- **Trade-off:** No wrapper-enforced lockdown means the security benefit
  (dependency-confusion resistance) depends entirely on the host config and the
  feed's upstream setup. Accepted: faithfulness to native behaviour was the
  stated goal, and forcing policy in the wrapper would diverge from it.

## Migration Plan

Purely additive. No existing flag behaviour, default, or image content changes.
Rollback is removing the `--registry` branch from `run.sh` — localized and
side-effect free outside its own opt-in path.

## Open Questions

- Should `--registry` later relocate npm's `userconfig` (and uv's config) onto
  a non-persisted path so an in-container `npm login` can't leave a token in the
  `claude-code-root` volume? Deferred under D6 until a real workflow needs it.
- Should there be a convenience that runs `aws codeartifact get-authorization-token`
  on the host and injects the result, for the common CodeArtifact case? Kept out
  of v1 to preserve registry-agnosticism; a documented host-side recipe covers
  it for now.
