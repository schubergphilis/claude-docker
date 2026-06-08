## 1. Image: install git-lfs

- [x] 1.1 Add `git-lfs` to the `apt-get install --no-install-recommends` list next to `git` in `Dockerfile:59` (unpinned, same as `git`/`tmux`/`jq`)
- [x] 1.2 In the same `RUN` (after the install, before `rm -rf /var/lib/apt/lists/*`), add `git lfs install --system --skip-repo` so the LFS filters are registered in the system gitconfig baked into the image
- [ ] 1.3 Build the image: `docker build -t claude-code:local ./claude-docker` succeeds on the local arch

## 2. Verify the fix

- [ ] 2.1 Presence: `docker run --rm claude-code:local git lfs version` prints a version, and `docker run --rm claude-code:local git config --system --get filter.lfs.process` prints `git-lfs filter-process`
- [ ] 2.2 Worktree regression: with an LFS-backed repo (a repo whose `.git/config` has `[filter "lfs"]` with `required = true`) mounted via `claude-docker`, run `git worktree add .claude/worktrees/test -b test` inside the container and confirm it completes without the `git: 'lfs' is not a git command` / `external filter 'git-lfs filter-process' failed` error and the session starts normally
- [ ] 2.3 Non-LFS unaffected: confirm `git worktree add` and a normal checkout in a non-LFS repo still behave as before

## 3. Documentation

- [x] 3.1 Add `git-lfs` to the bundled-tools line in `README.md` (the "CLI tools are preinstalled (...)" sentence near the top)

## 4. Validation

- [x] 4.1 `openspec validate add-git-lfs --strict` exits 0
- [ ] 4.2 `hadolint` (or the project's lint step) passes on the modified `Dockerfile`
