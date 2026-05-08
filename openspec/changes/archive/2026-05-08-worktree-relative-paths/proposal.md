## Why

Git worktrees embed absolute paths in their `.git` link files, so a worktree created on the host breaks when the same filesystem is accessed from inside `claude-docker` (and vice versa) — the host and container see the same files at different absolute paths. Today this forces users to run `git worktree repair` after every environment switch. Git 2.48 added relative-path support (`worktree.useRelativePaths`), which makes the embedded paths portable across host/container as long as the worktree's location relative to the repo's `.git/` is preserved — exactly the case for nested layouts like `<repo>/.claude/worktrees/<name>`.

A naive host-side-only opt-in does NOT work: `git worktree repair --relative-paths` (and any subsequent worktree mutation) sets `extensions.relativeWorktrees = true` in the repo's `.git/config` as a safety lock, and any git < 2.48 then refuses to operate on the repo at all (`fatal: unknown repository extension found: relativeworktrees`). Verified live with this repo: the on-disk relative-path *format* is fully readable by git 2.39, but the extension flag is a hard gate. Both host and container therefore need git ≥ 2.48 for the workflow to function.

## What Changes

- **Dockerfile**: switch the base image from `node:20-bookworm-slim` to `ubuntu:26.04` (LTS, just released). Ubuntu 26.04's main archive ships git 2.53.0 — clean apt install, no from-source build, no apt-pinning gymnastics. Install Node 20 LTS via NodeSource (canonical Node-on-Debian/Ubuntu installer; Debian's `node:` images don't have a variant that satisfies our git constraint).
- **README "Git worktrees" section**: lead with `worktree.useRelativePaths=true` + `git worktree repair --relative-paths` as the recommended workflow; demote `git worktree repair` (no flag) to a fallback for hosts on git < 2.48 and for sibling-flattened mounts. Document the host git ≥ 2.48 requirement.
- **`multi-workspace-mounts` spec**: split the existing "Sibling worktrees supported" requirement — one new requirement for nested-layout worktrees (no repair needed; covers both host-created and container-created worktrees because both ends now write relative paths), and a modified requirement for the existing sibling-flattened case (repair still required because the relative offset between worktree and repo differs between host and container).

No breaking changes for the legacy workflow: users who don't opt in keep the absolute-path behavior and the existing `git worktree repair` story continues to work. Image size impact: minimal (~5–10 MB delta from a leaner from-source build minus removing the apt `git` package).

## Capabilities

### New Capabilities

*(none — this change extends an existing capability)*

### Modified Capabilities

- `multi-workspace-mounts`: changes the "Sibling worktrees supported" requirement. Today it requires users to run `git worktree repair` inside the container. The new behavior splits the concern in two — adds a new requirement for nested-layout worktrees (worktree directory lives inside the repo tree) that work without repair when `worktree.useRelativePaths` is configured (host-side opt-in, which the bumped container git can also write/read), and modifies the existing sibling-flattened requirement to clarify *why* repair is still needed there (the basename-flattening at `/workspaces/<basename>` does not preserve the host's relative offset between worktree and repo).

## Impact

- **Code**: `claude-docker/Dockerfile` (base swap to `ubuntu:26.04` + NodeSource for Node 20), `claude-docker/README.md` (Git worktrees section). No `run.sh` changes.
- **Spec**: `openspec/specs/multi-workspace-mounts/spec.md` (split one requirement into two).
- **User-facing**: users who opt in to `worktree.useRelativePaths=true` on the host stop needing the in-container `git worktree repair` step for nested worktrees, and the same applies to worktrees created inside the container. Users who don't opt in see no change.
- **Build time**: roughly neutral. Slightly more apt fetching (NodeSource adds one apt source), but no from-source compilation.
- **Image size**: small delta (~10–20 MB). Ubuntu's base layer is a touch larger than Debian's; the apt `git` install is its standard size.
- **Trust model**: NodeSource is the canonical Node binary distributor for Debian/Ubuntu — its repo is signed with a pinned keyring fetched at build (same pattern as the existing `gh` install). All other tooling (`gh`, `glab`, `aws-cli`, `uv`) is unchanged and continues to use the existing sha256 pinning.
- **Compatibility caveat**: the base swap is the larger risk surface, not the git bump. Need to verify on first build that `gh`/`glab` (`.deb` and apt-source installs), AWS CLI v2, `uv` (glibc binary), and the npm-installed CLIs all work on Ubuntu 26.04 the same way they did on Debian bookworm. All are glibc-compatible by design, so no regressions are expected, but build-time verification is required.
