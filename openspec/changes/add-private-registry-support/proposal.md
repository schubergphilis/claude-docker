## Why

Teams that mirror their dependencies through a private package registry — AWS
CodeArtifact, Artifactory, Nexus, GitLab/Azure package feeds — use those
registries in CI and want the same resolution behaviour when Claude runs
`uv` / `pnpm`, or a pip-based tool (`pip`, `pipenv`), inside the container.
Today the bundled package managers only ever see the public npm registry and
PyPI; there is no path to point them at a private feed short of pasting registry
URLs and tokens into the container by hand each session.

The image already ships `uv`, `uvx`, `pnpm`, and `pnpx`, and every ecosystem
already knows how to talk to a private registry through its own native
configuration — `~/.npmrc` for npm/pnpm; `UV_INDEX_*` env vars + `~/.netrc` for
uv; `pip.conf` + `PIP_*` env vars + `~/.netrc` for pip, with pipenv delegating
to pip. The missing piece is purely a wrapper concern: surfacing that host-side
native config into the container under an explicit opt-in, the same way
`--aws` / `--gh` / `--glab` / `--tfe` already surface other host credentials.
(The image ships no Python runtime, so `pip`/`pipenv` themselves run via
`uvx pipenv` or a child image — see the design doc; the forwarded config flows
through to whichever pip executes.)

## What Changes

- **Add a `--registry` opt-in flag** to `run.sh` that forwards the host's
  *native* `uv` and `npm`/`pnpm` private-registry configuration into the
  container. No flag → no registry config or registry credentials reach the
  container; the package managers use their public defaults. Same explicit-
  consent posture as the existing credential flags.
- **Mount native config files read-only** when present on the host (silent
  no-op otherwise): `~/.npmrc` → `/root/.npmrc`, `~/.netrc` → `/root/.netrc`,
  `~/.config/uv/uv.toml` → `/root/.config/uv/uv.toml`, and the platform-aware
  pip config — `~/.config/pip/pip.conf` (Linux) or
  `~/Library/Application Support/pip/pip.conf` (macOS) → `/root/.config/pip/pip.conf`.
  (`~/.netrc`, already mounted for uv, is also pip's and pipenv's native auth
  channel, so it is shared, not duplicated.)
- **Forward native env vars** when set on the host: `npm_config_registry`,
  `NPM_CONFIG_REGISTRY`, `NODE_AUTH_TOKEN`, `NPM_TOKEN`, `UV_INDEX_URL`,
  `UV_DEFAULT_INDEX`, `UV_EXTRA_INDEX_URL`, `UV_INDEX`, `UV_NETRC`,
  `UV_KEYRING_PROVIDER`, `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`,
  `PIP_TRUSTED_HOST`, `PIPENV_PYPI_MIRROR` — plus every host variable matching
  `UV_INDEX_*_USERNAME` / `UV_INDEX_*_PASSWORD` (uv derives these names from a
  user-chosen index name, so they can't be enumerated by a fixed list).
- **Surface the opt-in in the statusline** by appending `registry` to the
  `docker:` tag list.
- **Document** the flag (README opt-in table, auth model, usage including the
  AWS CodeArtifact token recipe) and add a threat-model note that `--registry`
  *narrows* the runtime-fetch surface to the configured feed but is registry
  resolution policy, not network egress filtering.

Deliberately *not* in scope (deferred, to be revisited after real usage):

- **No invented configuration.** The wrapper forwards native config verbatim;
  it does not define `CLAUDE_DOCKER_*` registry variables or translate between
  ecosystems. Resolution policy (private-only vs. private-plus-public) is
  whatever the host's native config already expresses.
- **No wrapper-side lockdown flag.** Confining resolution to the private feed
  is the native effect of setting a default registry/index in the host config;
  re-adding public registries is done in that same native config. The wrapper
  imposes no policy of its own.
- **No in-container token refresh.** A token captured at launch (e.g. a
  short-lived CodeArtifact token in `~/.npmrc`) freezes for the container's
  life; refresh = restart. Same posture as `--aws` SSO creds.
- **No network egress filtering.** `--registry` changes where the package
  managers *resolve* packages; it does not stop `npx`, `git+https` installs,
  `curl`, or any other egress. It is dependency-resolution hygiene, not a
  network boundary.

## Capabilities

### New Capabilities

None. This extends the existing `package-managers` capability rather than
introducing a new one.

### Modified Capabilities

- `package-managers`: adds a requirement that `run.sh` expose host-native
  private-registry configuration to `uv`, `pnpm`, and pip-based tools
  (`pip`/`pipenv`) under an explicit `--registry` opt-in (read-only config-file
  mounts + native env-var forwarding, including dynamic uv per-index credential
  vars), with default-deny when the flag is absent.

## Impact

- **Code**: `claude-docker/run.sh` (parse `--registry`; mount `~/.npmrc` /
  `~/.netrc` / `~/.config/uv/uv.toml` and the platform-aware pip config
  read-only when present; forward the static native env vars — npm, uv, and
  `PIP_*` / `PIPENV_PYPI_MIRROR` — and the dynamic `UV_INDEX_*_USERNAME/_PASSWORD`
  vars; append `registry` to the statusline tag; add a `--help` row).
- **Docs**: `claude-docker/README.md` (opt-in table row, auth-model entry,
  usage section with the CodeArtifact recipe, threat-model note).
- **Specs**: one delta to `package-managers`.
- **Image**: none. `uv` / `uvx` / `pnpm` / `pnpx` are already installed; this
  change is wrapper + docs only.
- **No breaking changes**: existing flags and the no-flag default are
  unchanged; `--registry` is purely additive and composes with every other
  flag (it does not require `--aws`).
