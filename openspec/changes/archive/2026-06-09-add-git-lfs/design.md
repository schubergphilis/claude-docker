## Context

`run.sh` builds a container-only `.git/config` overlay (run.sh:307–342) that
copies the host repo's `.git/config` verbatim and appends the relative-worktree
extension block. When the host repo uses Git LFS, the copied config carries
`[filter "lfs"]` (`clean` / `smudge` / `process`, `required = true`). The image
installs `git` (Dockerfile:59) but not `git-lfs`, so any git checkout that
invokes the filter — notably the HEAD checkout performed by `git worktree add` —
fails with `git: 'lfs' is not a git command` and `external filter 'git-lfs
filter-process' failed`. With `required = true` (LFS's default) this is fatal,
so worktree creation aborts and the session fails to start.

The fix is a build-time image change only. There is no host-side component and
no new `run.sh` flag.

## Goals / Non-Goals

**Goals:**
- `git worktree add` and any other checkout succeed inside the container on
  LFS-backed repos.
- LFS smudge/clean filtering works regardless of where the host kept its LFS
  filter config (repo-local, copied by the overlay; or host-global, not
  inherited).
- Keep the change minimal and consistent with how `git` is already installed.

**Non-Goals:**
- No new `run.sh` flag, credential mount, or env-var forwarding.
- No LFS-specific authentication handling (`git lfs pull` reuses the same
  remotes git already reaches; auth is the user's existing git/remote setup).
- No version-pinning of `git-lfs` beyond what the distro archive provides
  (matches the existing unpinned `git`).

## Decisions

**Decision: install `git-lfs` from the Ubuntu archive, unpinned, in the existing
apt block.**
Add `git-lfs` to the `apt-get install` list next to `git` (Dockerfile:59).
- *Why not pin a version + sha256 (the tfenv/glab/aws pattern)?* Those tools are
  third-party direct downloads. `git-lfs` is in Ubuntu's main archive, same as
  `git`/`tmux`/`jq`; pinning archive packages breaks on every repo refresh,
  which is exactly why `.hadolint.yaml` waives DL3008 with a documented
  rationale. Pinning `git-lfs` but not `git` would be inconsistent.

**Decision: register filters system-wide with `git lfs install --system
--skip-repo` at build time.**
- *Why `--system`?* It writes `filter.lfs.*` into the system gitconfig baked
  into the image layer, so LFS works even when the host's filter config lived
  only in `~/.gitconfig` (which the container does not inherit — only
  `GIT_AUTHOR_*` / `GIT_COMMITTER_*` identity is forwarded, per README "Git
  identity"). Repo-local config still flows through the overlay and transparently
  overrides the system entry (same value either way).
- *Why `--skip-repo`?* The Dockerfile build has no repo context; `--skip-repo`
  avoids git-lfs trying to touch a working-tree repo and keeps the step to a
  pure system-config write.
- *Alternative considered — rely solely on the copied repo-local config.*
  Rejected: it leaves the global-only host-config case broken (files silently
  pass through as unsmudged pointers), and `git lfs install --system` is one
  line.

**Decision: place the requirement under `external-cli-tools`, not
`multi-workspace-mounts`.**
- The observable trigger is worktree creation (a `multi-workspace-mounts`
  concern), but the change itself is "the image ships a binary on PATH" — the
  same shape as the `tfenv` addition, which also lives under
  `external-cli-tools`. One spec, consistent home. The worktree-checkout case is
  captured as a scenario so the behavioural trigger is still spec-tested.

## Risks / Trade-offs

- **[Image size grows by the `git-lfs` package (~10–15 MB).]** → Acceptable;
  trivial next to the Node/AWS-CLI layers already present.
- **[`git lfs pull` of large objects could be triggered under `--yolo` by a
  prompt-injected workspace.]** → No new blast radius: it uses the repo's
  existing remotes, which git can already reach; the threat model already
  documents full outbound network. Not adding a threat-model bullet because no
  new execution/egress primitive is introduced (unlike `tfenv install` / `uvx`).
- **[Unpinned package means a compromised Ubuntu archive could serve a malicious
  `git-lfs`.]** → Same trust assumption already accepted for `git`/`tmux`/`jq`;
  the base image is digest-pinned. No regression.

## Migration Plan

Rebuild the image (`docker build -t claude-code:local ./claude-docker`). No host
config change, no data migration, no rollback complexity — reverting the
Dockerfile and rebuilding restores prior behaviour. Non-LFS repos are entirely
unaffected.
