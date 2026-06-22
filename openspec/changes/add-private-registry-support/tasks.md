## 1. Wrapper: --registry flag

- [ ] 1.1 In `run.sh`, add `WITH_REGISTRY=0` alongside the other `WITH_*` initializers and a `--registry) WITH_REGISTRY=1 ;;` arm in the case statement
- [ ] 1.2 Under `--registry`, append read-only mounts to `MOUNT_ARGS`, each guarded by an existence check (silent no-op otherwise, mirroring `--tfe`'s `[ -f ... ]` pattern): `~/.npmrc` → `/root/.npmrc:ro`, `~/.netrc` → `/root/.netrc:ro`, `~/.config/uv/uv.toml` → `/root/.config/uv/uv.toml:ro`
- [ ] 1.3 Under `--registry`, add the static native env-var names to the `ENV_VARS` array so the existing `[ -n "${!v:-}" ]` filter forwards them only when set: `npm_config_registry NPM_CONFIG_REGISTRY NODE_AUTH_TOKEN NPM_TOKEN UV_INDEX_URL UV_DEFAULT_INDEX UV_EXTRA_INDEX_URL UV_INDEX UV_NETRC UV_KEYRING_PROVIDER`
- [ ] 1.4 Under `--registry`, scan exported host variables (`compgen -e`) and append `-e "$name"` to `ENV_ARGS` for every name matching `UV_INDEX_*_USERNAME` or `UV_INDEX_*_PASSWORD` that is set; scope strictly to those two suffixes (do not blanket-forward `UV_*` — a host `UV_CACHE_DIR`/path-valued var would break in-container). Bash 3.2 + `set -u` safe.
- [ ] 1.5 Append `registry` to `DOCKER_FLAGS` when `WITH_REGISTRY=1` so the statusline tag reflects the opt-in
- [ ] 1.6 Update the `print_help` heredoc with a `--registry` row matching the `--aws`/`--gh`/`--glab`/`--tfe` style (one-line summary: forward host-native uv/npm/pnpm private-registry config — `~/.npmrc`, `~/.netrc`, `~/.config/uv/uv.toml` read-only + `UV_INDEX_*` / `npm_config_registry` env)

## 2. Smoke tests against scenarios

- [ ] 2.1 No-flag invariant: with a host `~/.npmrc` setting a private `registry=` and `UV_DEFAULT_INDEX` exported, `claude-docker ~/repo` (no flag) → inside the container `/root/.npmrc` lacks the host config, `echo $UV_DEFAULT_INDEX` is empty, and `pnpm config get registry` returns the public npm default
- [ ] 2.2 `--registry` npmrc mount: with a host `~/.npmrc` pointing at a private registry, `claude-docker --registry ~/repo` exposes it read-only — `pnpm config get registry` returns the private URL and an in-container write to `/root/.npmrc` fails with EROFS
- [ ] 2.3 `--registry` uv env forwarding incl. dynamic vars: with `UV_DEFAULT_INDEX`, `UV_INDEX_INTERNAL_USERNAME`, and `UV_INDEX_INTERNAL_PASSWORD` exported on the host, `claude-docker --registry ~/repo` forwards all three; without `--registry`, none are present
- [ ] 2.4 `--registry` silent absence: with no host `~/.npmrc`/`~/.netrc`/`uv.toml` and none of the forwarded env vars set, `claude-docker --registry ~/repo` starts cleanly with no error and the package managers use public defaults
- [ ] 2.5 Statusline tag includes `registry`: launch `claude-docker --registry --gh ~/repo` and confirm the statusline prefix shows `registry` in the `docker:` tag list (e.g. `docker:gh,registry`)
- [ ] 2.6 End-to-end (CodeArtifact, manual): on a host with `aws codeartifact login --tool npm` having written a token into `~/.npmrc`, `claude-docker --registry ~/repo` → `pnpm add <a-package-in-the-feed>` resolves via the private registry

## 3. Documentation

- [ ] 3.1 Add a `--registry` row to the **Credential opt-in** table in `README.md`, matching the `--aws`/`--gh`/`--glab`/`--tfe` voice (mounts `~/.npmrc` / `~/.netrc` / `~/.config/uv/uv.toml` read-only when present; forwards `UV_INDEX_*` / `npm_config_registry` / `NODE_AUTH_TOKEN` env; off by default)
- [ ] 3.2 Extend the **Auth model** section with a `--registry` entry: source of config (host-native files + env), read-only mounts, token freezes at launch (refresh = restart), and that it composes with but does not require `--aws`
- [ ] 3.3 Add a usage paragraph showing the standard flow, including the AWS CodeArtifact recipe: `aws codeartifact login --tool npm --domain … --repository …` (and the uv `UV_INDEX_*` / `aws codeartifact get-authorization-token` equivalent) on the host → `claude-docker --registry ~/repo`
- [ ] 3.4 Add a **Threat model** note: `--registry` *narrows* package resolution to the configured feed (host-config-dependent) but is registry-resolution config, **not** network egress filtering — `npx`, `git+https` installs, and other egress are unaffected; and `~/.npmrc`/`~/.netrc` tokens are readable in-container under the flag (same class as `--gh`/`--glab`)

## 4. Validation

- [ ] 4.1 `openspec validate add-private-registry-support --strict` exits 0
- [ ] 4.2 `claude-docker --help` round-trips: every wrapper flag in the help text has a matching case arm and vice versa (including `--registry`)
- [ ] 4.3 Spot-check `--ephemeral` composition: `claude-docker --ephemeral --registry ~/repo` forwards the config/env but skips the named volumes; confirm no dependence on `claude-code-root` in the `--registry` path (consistent with D6 — no masking)
