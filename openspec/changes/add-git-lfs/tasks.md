## 1. Image: install git-lfs

- [x] 1.1 Add `git-lfs` to the `apt-get install --no-install-recommends` list next to `git` in `Dockerfile:59` (unpinned, same as `git`/`tmux`/`jq`)
- [x] 1.2 In the same `RUN` (after the install, before `rm -rf /var/lib/apt/lists/*`), add `git lfs install --system --skip-repo` so the LFS filters are registered in the system gitconfig baked into the image
- [x] 1.3 Build to a **disposable** tag so your working `claude-code:local` is never touched — the smoke tests below all run against this throwaway tag and it gets deleted in 2.4:

  ```bash
  docker build -t claude-code:git-lfs-test ./claude-docker   # succeeds on local arch
  ```

  Verified in CI (PR #37, "Docker build (validate, no push)"): `git-lfs 3.7.1-1` installed and `git lfs install --system --skip-repo` printed "Git LFS initialized."

## 2. Verify the fix (host with Docker — disposable image, isolated from `claude-code:local`)

All checks run via plain `docker run` against `claude-code:git-lfs-test`, so neither your `claude-code:local` image nor your real repos are involved.

- [ ] 2.1 Presence: git-lfs is on PATH and the filters are registered system-wide:

  ```bash
  docker run --rm claude-code:git-lfs-test git lfs version
  docker run --rm claude-code:git-lfs-test git config --system --get filter.lfs.process
  # expect: a version string, then `git-lfs filter-process`
  ```

- [ ] 2.2 Worktree regression (the actual bug). Build a throwaway LFS fixture on the host (needs host git-lfs — you have it), then do the checkout that used to fail, inside the container:

  ```bash
  fix=$(mktemp -d)/lfs-fixture && git init -q "$fix" && ( cd "$fix" \
    && git config user.email t@e.x && git config user.name t \
    && git lfs install --local \
    && git lfs track '*.bin' >/dev/null \
    && printf 'hello lfs\n' > asset.bin \
    && git add .gitattributes asset.bin && git commit -qm fixture )
  # The fixture's .git/config now carries [filter "lfs"] required=true, and the
  # LFS object lives in .git/lfs/objects (mounted), so smudge needs no network.

  docker run --rm -v "$fix":/repo -w /repo claude-code:git-lfs-test \
    git worktree add /tmp/wt -b test
  # PASS: checkout completes. Pre-fix this aborted with
  #   "git: 'lfs' is not a git command" / "external filter 'git-lfs filter-process' failed".
  ```

- [ ] 2.3 Non-LFS unaffected: the same worktree checkout on a plain repo still works:

  ```bash
  plain=$(mktemp -d)/plain && git init -q "$plain" && ( cd "$plain" \
    && git config user.email t@e.x && git config user.name t \
    && echo hi > a.txt && git add a.txt && git commit -qm init )
  docker run --rm -v "$plain":/repo -w /repo claude-code:git-lfs-test \
    git worktree add /tmp/wt2 -b test
  # PASS: behaves exactly as before; no LFS filter involved.
  ```

- [ ] 2.4 Clean up — remove the disposable image and fixtures (`claude-code:local` was never modified):

  ```bash
  docker rmi claude-code:git-lfs-test
  rm -rf "$(dirname "$fix")" "$(dirname "$plain")"
  ```

## 3. Documentation

- [x] 3.1 Add `git-lfs` to the bundled-tools line in `README.md` (the "CLI tools are preinstalled (...)" sentence near the top)

## 4. Validation

- [x] 4.1 `openspec validate add-git-lfs --strict` exits 0
- [x] 4.2 `hadolint` (or the project's lint step) passes on the modified `Dockerfile` (verified in CI, PR #37 "Lint" job: success)
