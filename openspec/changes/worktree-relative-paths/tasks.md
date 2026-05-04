## 1. Container base-image swap to Ubuntu 26.04 LTS

- [x] 1.1 Replace `FROM node:20-bookworm-slim@sha256:...` with `FROM ubuntu:26.04@sha256:...` in the Dockerfile. Pin the multi-arch index digest (lookup: `docker buildx imagetools inspect ubuntu:26.04 --format '{{.Manifest.Digest}}'`).
- [x] 1.2 Add a `NODE_VERSION` ARG (NodeSource format: `20.20.2-1nodesource1`) and a `Bump with: ...` comment for refreshing it.
- [x] 1.3 In the main apt install layer, add NodeSource as an apt source (signed by a build-time-fetched keyring at `/etc/apt/keyrings/nodesource.gpg`), then install `nodejs=${NODE_VERSION}` alongside `git`, `tmux`, `ncurses-term`, `jq`, `less`, `openssh-client`, `unzip`. Drop the bookworm-specific bootstrapping (none needed; Ubuntu's apt machinery is identical).
- [ ] 1.4 Verify image builds clean on `amd64` and `arm64` (`docker buildx build --platform linux/amd64,linux/arm64 -t claude-code:local ./claude-docker`).
- [ ] 1.5 Verify `git --version` inside the built image reports ≥ 2.48 (target: 2.53.0 from Ubuntu archive).
- [ ] 1.6 Verify all other bundled CLIs still work post-swap: `node --version` (matches `NODE_VERSION`), `gh --version`, `glab --version`, `aws --version`, `uv --version`, `pnpm --version`, `claude --version`, `openspec --version`. Any failure here means the base swap broke something — fix or roll back.

## 2. Container-side acceptance check

- [ ] 2.1 Inside the rebuilt container, in a scratch repo, run `git config worktree.useRelativePaths true && git worktree add .claude/worktrees/wt -b wt` and confirm both `<repo>/.git/worktrees/wt/gitdir` and `<repo>/.claude/worktrees/wt/.git` contain relative paths (no leading `/`).
- [ ] 2.2 Confirm `extensions.relativeWorktrees = true` is set in the scratch repo's `.git/config`, and that subsequent git commands (`git status`, `git worktree list`, `git commit`) all succeed in the container.
- [ ] 2.3 Move the scratch repo to a different absolute path inside the container and confirm `git status` in the worktree still succeeds without `git worktree repair`.

## 3. Host-to-container round-trip check

- [ ] 3.1 On the host (with git ≥ 2.48), confirm the existing worktree at `<repo>/.claude/worktrees/git-worktree-relative-path` is still in the relative-path state from earlier in this change's investigation (or rerun `git worktree repair --relative-paths <wt-path>` if rolled back).
- [ ] 3.2 Confirm `extensions.relativeWorktrees = true` is set in `<repo>/.git/config`.
- [ ] 3.3 Run `claude-docker <repo>` (with the rebuilt image) and verify `git status` inside the mounted worktree path works without any repair step and without the "unknown repository extension" error.
- [ ] 3.4 Inside the container, create a fresh worktree (`git worktree add .claude/worktrees/test-from-container -b test-from-container`), exit, and confirm `git status` in that worktree works on the host without `git worktree repair`.

## 4. Documentation

- [x] 4.1 Rewrite the README "Git worktrees" section: lead with `worktree.useRelativePaths=true` + `git worktree repair --relative-paths` as the recommended workflow for nested worktrees; demote `git worktree repair` (no flag) to the fallback for sibling-flattened layouts and hosts on git < 2.48.
- [x] 4.2 Note the host git version requirement (≥ 2.48) and that the bumped container git makes worktrees-created-inside-the-container also portable.
- [x] 4.3 Cross-check the README change against the spec scenarios — wording in the README should match the cases the spec calls out (nested vs. sibling-flattened).
- [x] 4.4 Re-read the README "Git worktrees" section after the Dockerfile change lands and remove the "container's git currently writes absolute paths" caveat that was added under the deferred-bump assumption.

## 5. Spec sync

- [x] 5.1 Run `openspec validate worktree-relative-paths` to confirm the delta spec parses cleanly.
- [ ] 5.2 On archive, confirm `openspec/specs/multi-workspace-mounts/spec.md` reflects both the modified "Sibling worktrees supported" requirement and the added "Nested worktrees portable via relative paths" requirement.
