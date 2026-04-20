## 1. Dockerfile changes

- [x] 1.1 Add `ARG OPENSPEC_VERSION=1.3.0` to the version-ARG block at the top of `claude-docker/Dockerfile` (pin to whatever is current at merge time).
- [x] 1.2 Extend the existing `RUN npm install -g --ignore-scripts "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"` line to also install `"@fission-ai/openspec@${OPENSPEC_VERSION}"` in the same layer.
- [x] 1.3 Verify `grep '^ARG OPENSPEC_VERSION' claude-docker/Dockerfile` returns exactly one line.

## 2. Build verification

- [ ] 2.1 `docker build -t claude-code:local ./claude-docker` succeeds on the local arch (amd64 or arm64).
- [ ] 2.2 `docker run --rm claude-code:local openspec --version` prints the value of `OPENSPEC_VERSION`.
- [ ] 2.3 `docker run --rm claude-code:local openspec --help` exits 0 and shows the expected subcommands.
- [ ] 2.4 Cross-arch build check: `docker buildx build --platform linux/amd64,linux/arm64 ./claude-docker` succeeds (or run the build on both arches separately if buildx multi-platform is not available locally).

## 3. Negative-surface verification

- [x] 3.1 Confirm `claude-docker/run.sh` is unchanged (no new flag, mount, or env-var forward).
- [ ] 3.2 Confirm the set of bind-mounts and forwarded env vars observed with `docker inspect` on a live container is unchanged from `main`.
- [ ] 3.3 Run `claude-docker ~/tmp-empty-dir` with no `openspec`-related host state, then inside the container run `cd /workspaces/tmp-empty-dir && openspec --help` — it should succeed with zero host dependencies.

## 4. Documentation

- [x] 4.1 Update `claude-docker/README.md` to mention `openspec` in the list of bundled CLIs (alongside `gh`, `glab`, `aws`).
- [x] 4.2 Add a one-line note that `openspec` requires no credential flags (distinguishing it from the `--aws` / `--gh` / `--glab` entries).

## 5. Archive readiness

- [x] 5.1 `openspec validate add-claude-docker-openspec` reports no errors.
- [x] 5.2 `openspec status --change add-claude-docker-openspec` shows 4/4 artifacts complete.
- [ ] 5.3 All tasks in this file are checked off.
