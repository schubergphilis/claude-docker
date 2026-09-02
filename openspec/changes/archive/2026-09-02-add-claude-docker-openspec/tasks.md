## 1. Dockerfile changes

- [x] 1.1 Pin the openspec version in the generated `pins/openspec.env` fragment (`OPENSPEC_VERSION`); verify `python3 update_pins.py --list-npm-tools` lists `openspec` with a non-empty version. (Originally landed as `ARG OPENSPEC_VERSION=1.3.0`; `automate-version-pins` migrated every automated pin to `pins/`.)
- [x] 1.2 Install `"@fission-ai/openspec@${OPENSPEC_VERSION}"` in the existing `npm install -g --ignore-scripts` RUN; verify `Dockerfile:222-229` COPYs and sources the claude-code, openspec, and pnpm fragments in that one layer.
- [x] 1.3 Verify the Dockerfile carries no literal openspec version: `grep -c 'OPENSPEC_VERSION=' Dockerfile` is 0, and the only `OPENSPEC` hit is the `${OPENSPEC_VERSION}` expansion on line 226.

## 2. Build verification

- [x] 2.1 Verify `openspec` is on the default PATH in a built image and provided by the image itself: `which openspec` → `/usr/bin/openspec`, a symlink to `../lib/node_modules/@fission-ai/openspec/bin/openspec.js`, with no openspec entry in `/proc/self/mountinfo`.
- [x] 2.2 Verify the image reports the pinned version: `openspec --version` → `1.10.0`, matching `OPENSPEC_VERSION` in `pins/openspec.env`. Checked in a live claude-docker container rebuilt from `main` two days before archiving, whose `claude` (`2.1.241`) and `pnpm` (`11.23.0`) also match their committed pins — so the image under test is a recent build from these fragments, not a stale one.
- [x] 2.3 Verify `openspec --help` exits 0 and lists the expected subcommands (`init`, `update`, `validate`, `archive`, …).
- [x] 2.4 Cross-arch check. **arm64:** verified directly — 2.1-2.3 were run in an `aarch64` container (`dpkg --print-architecture` → `arm64`, node reports `arm64/linux`) built locally from `main` on Apple Silicon (M2 Pro), so the build and the CLI both work there. **amd64:** the build is verified by CI's `docker-build` job on every PR — a failed `npm install` in the shared layer fails the build, so a broken openspec install cannot merge — but `openspec --version` itself is only exercised on arm64. Residual gap accepted: `@fission-ai/openspec` is pure JS on Node, with no native artifact that could differ per arch.

## 3. Negative-surface verification

- [x] 3.1 Verify `run.sh` gained no openspec flag, mount, or env-var forward: `grep -i openspec run.sh entrypoint.sh` returns no hits.
- [x] 3.2 Verify the bind-mount and env-forward set is unchanged by construction — with no openspec reference anywhere in `run.sh` or `entrypoint.sh` there is no code path that could add one, which covers every flag combination rather than the single container a `docker inspect` diff would sample.
- [x] 3.3 Verify zero host dependency: `openspec --version` and `openspec --help` both succeed against the image's own binary (2.1), so no host install or host config is consulted.

## 4. Documentation

- [x] 4.1 `README.md:8` lists `openspec` among the preinstalled CLI tools.
- [x] 4.2 `README.md:10` notes that only `gh`, `glab`, and `aws` need a flag to see host credentials and "the rest work out of the box", distinguishing `openspec` from the `--aws` / `--gh` / `--glab` entries.

## 5. Archive readiness

- [x] 5.1 `openspec validate add-claude-docker-openspec --strict` reports no errors.
- [x] 5.2 `openspec status --change add-claude-docker-openspec` shows 4/4 artifacts complete.
- [x] 5.3 The spec delta opens with `## Purpose`, so archive does not leave a `TBD … Update Purpose after archive` placeholder in the new `openspec/specs/openspec-cli/spec.md`.
