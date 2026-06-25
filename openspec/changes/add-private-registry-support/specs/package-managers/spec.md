## ADDED Requirements

### Requirement: Private registry passthrough via --registry

`run.sh` SHALL provide a `--registry` opt-in flag that surfaces the host's
native `uv`, `npm`/`pnpm`, and pip-based (`pip`/`pipenv`) private-registry
configuration into the container using the package managers' own discovery
mechanisms, rather than any wrapper-specific configuration. When `--registry`
is NOT passed, no registry configuration and no registry credentials SHALL
reach the container, and the package managers SHALL fall back to their built-in
public defaults (the npm registry and PyPI). The flag SHALL compose with all
other flags and SHALL NOT require `--aws`.

This requirement governs registry *configuration* only. The image SHALL NOT be
required to ship `pip`, `pipenv`, or a Python runtime for this requirement to be
met; the forwarded pip configuration applies to whatever pip executes inside the
container (e.g. via `uvx pipenv` or a child image).

When `--registry` is set, `run.sh`:

- SHALL mount read-only, and only when present on the host (a missing file is a
  silent no-op), each of: the host npm config (`~/.npmrc`, or the file named by
  `npm_config_userconfig` / `NPM_CONFIG_USERCONFIG` when set) at `/root/.npmrc`,
  `~/.config/uv/uv.toml` at `/root/.config/uv/uv.toml`, and the
  platform-appropriate pip config — `~/.config/pip/pip.conf` on Linux or
  `~/Library/Application Support/pip/pip.conf` on macOS — at
  `/root/.config/pip/pip.conf`.
- SHALL NOT mount `~/.netrc`. Because netrc is a machine-keyed store that
  commonly holds credentials for hosts unrelated to the package registry,
  forwarding the whole file into a full-egress container is too broad; netrc-
  based registry auth is intentionally not supported by this flag (registry
  auth belongs in npmrc/pip.conf, the index URL, or `UV_INDEX_*_PASSWORD`).
- SHALL forward, only when set on the host, the native env vars
  `npm_config_registry`, `NPM_CONFIG_REGISTRY`, `NODE_AUTH_TOKEN`, `NPM_TOKEN`,
  `UV_INDEX_URL`, `UV_DEFAULT_INDEX`, `UV_EXTRA_INDEX_URL`, `UV_INDEX`,
  `UV_KEYRING_PROVIDER`, `PIP_INDEX_URL`, `PIP_EXTRA_INDEX_URL`,
  `PIP_TRUSTED_HOST`, and `PIPENV_PYPI_MIRROR`. It SHALL NOT forward `UV_NETRC`
  (it points uv at a netrc file that is no longer mounted).
- SHALL additionally forward every set host environment variable whose name
  matches `UV_INDEX_*_USERNAME` or `UV_INDEX_*_PASSWORD`, so uv's per-index
  credential variables (whose names derive from a user-chosen index name) reach
  the container without being individually enumerated, while other `UV_*`
  variables are NOT blanket-forwarded.
- SHALL append `registry` to the statusline opt-in tag list.

All mounted config files SHALL be read-only, so the container cannot mutate host
registry credentials and a `--registry` session cannot persist registry
credential state into the `claude-code-root` volume.

Resolution policy SHALL be whatever the host configuration expresses: the
wrapper imposes none of its own. Setting a default registry/index in the host
config natively replaces the public default (confining resolution to the
configured feed), and re-admitting public registries is expressed in the host's
own native config.

#### Scenario: no flag means no registry config reaches the container

- **GIVEN** the host has a `~/.npmrc` with a private `registry=` line and exports `UV_DEFAULT_INDEX`
- **WHEN** the user runs `claude-docker ~/repo` without `--registry`
- **THEN** `/root/.npmrc` inside the container does not contain the host's private registry config
- **AND** `echo $UV_DEFAULT_INDEX` inside the container is empty
- **AND** `pnpm config get registry` returns the public npm default

#### Scenario: --registry mounts host npmrc read-only

- **GIVEN** the host has a `~/.npmrc` configuring a private registry with an auth token
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** `/root/.npmrc` inside the container contains the host file's contents
- **AND** `pnpm config get registry` returns the private registry URL
- **AND** a write to `/root/.npmrc` from inside the container fails with EROFS

#### Scenario: --registry mounts host pip config and forwards PIP_* env

- **GIVEN** the host has a pip config (at its platform-appropriate user location) setting a private `index-url`, and exports `PIP_INDEX_URL`
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** `/root/.config/pip/pip.conf` inside the container contains the host pip config
- **AND** `echo $PIP_INDEX_URL` inside the container prints the host value
- **AND** a pip-based install (e.g. via `uvx pipenv`) resolves against the private index
- **AND** without `--registry`, `/root/.config/pip/pip.conf` is absent and `echo $PIP_INDEX_URL` is empty

#### Scenario: --registry forwards uv index env vars including dynamic credential vars

- **GIVEN** the host exports `UV_DEFAULT_INDEX=https://example.test/simple/`, `UV_INDEX_INTERNAL_USERNAME=aws`, and `UV_INDEX_INTERNAL_PASSWORD=tok`
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** all three variables are present in the container environment
- **AND** other unrelated `UV_*` host variables (e.g. `UV_CACHE_DIR`) are not forwarded

#### Scenario: --registry is silent when no host registry config exists

- **GIVEN** the host has no `~/.npmrc`, no `~/.netrc`, no `~/.config/uv/uv.toml`, and none of the forwarded env vars set
- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** the container starts without error
- **AND** the package managers fall back to their public defaults

#### Scenario: statusline tag reflects the opt-in

- **WHEN** the user runs `claude-docker --registry ~/repo`
- **THEN** the statusline `docker:` prefix includes `registry` in the opt-in tag list
