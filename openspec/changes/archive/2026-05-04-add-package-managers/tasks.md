## 1. Dockerfile — uv

- [x] 1.1 Add `UV_VERSION=0.11.8` to the version ARG block at the top of the Dockerfile
- [x] 1.2 Add `UV_SHA256_X86_64=56dd1b66701ecb62fe896abb919444e4b83c5e8645cca953e6ddd496ff8a0feb` and `UV_SHA256_AARCH64=eee8dd658d20e5ac85fec9c2326b6cbc9d83a1eef09ef07433e58698ac849591` ARGs alongside the version
- [x] 1.3 Insert a new RUN block after the AWS CLI block: arch-aware case statement (`x86_64`/`aarch64`), curl the gnu-variant tarball from `github.com/astral-sh/uv/releases/download/${UV_VERSION}/`, `sha256sum -c` against the pinned ARG, extract to scratch dir, `install -m 0755 .../uv .../uvx /usr/local/bin/`, clean up
- [x] 1.4 Add a brief comment above the block explaining the gnu-vs-musl choice and the ARG-pinned sha256 rationale

## 2. Dockerfile — pnpm

- [x] 2.1 Add `PNPM_VERSION=10.33.2` to the version ARG block alongside `CLAUDE_CODE_VERSION` and `OPENSPEC_VERSION`
- [x] 2.2 Append `"pnpm@${PNPM_VERSION}"` as a third package on the existing `npm install -g --ignore-scripts` line (do NOT introduce a new RUN block)

## 3. README — bundled CLIs and threat model

- [x] 3.1 Update the "Bundled CLIs on the default PATH" line at the top of `claude-docker/README.md` to include `uv`, `uvx`, `pnpm`, `pnpx`
- [x] 3.2 Add a runtime-fetch bullet under the **Exposed** list in § Threat model covering `npx`, `pnpm dlx`, and `uvx`, identifying `uvx` as a new PyPI execution primitive and `pnpm dlx` as zero-marginal-blast-radius vs the already-reachable `npx`
- [x] 3.3 Add a one-sentence note in § Extending the image (from PR #17) that any extra package managers a child image installs *add* to the runtime-fetch surface, not replace it

## 4. Build verification

- [x] 4.1 Run `docker build -t claude-code:local ./claude-docker` on the host arch and confirm the build succeeds
- [x] 4.2 Run the build with `--platform linux/amd64` and `--platform linux/arm64` (whichever is not the host) to confirm both arches build cleanly
- [x] 4.3 Verify sha256 mismatch is fatal: temporarily flip one hex digit in `UV_SHA256_*` and confirm the build fails before extraction

## 5. Runtime smoke tests

- [x] 5.1 In a fresh container: `uv --version && uvx --version && pnpm --version` succeed; `which pnpx` resolves (pnpm 10 ships `pnpx` as a no-flag alias for `pnpm dlx`; spec scenario updated to match)
- [x] 5.2 In a fresh container: `pnpm dlx cowsay hello` fetches and runs without adding to global node_modules
- [x] 5.3 In a fresh container: `uvx ruff --version` fetches a Python runtime + the package and runs successfully
- [x] 5.4 Confirm `which uv uvx pnpm pnpx` all resolve to `/usr/local/bin/` or the npm global bin (no PATH shadowing)

## 6. Wrap-up

- [x] 6.1 Run `openspec validate add-package-managers` and confirm it passes
- [x] 6.2 Open PR targeting `main`, link to PR #17 (extension pattern), reference FU1 + FU2 as out-of-scope follow-ups in the PR description
- [ ] 6.3 After merge, run `openspec archive add-package-managers` to move the change into `openspec/changes/archive/` and sync the new `package-managers` capability into `openspec/specs/`
