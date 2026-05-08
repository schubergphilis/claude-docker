## Context

Git stores two link files for each worktree, both containing absolute paths by default:

1. `<worktree>/.git` — a text file with `gitdir: <abs-path-to-repo>/.git/worktrees/<name>`
2. `<repo>/.git/worktrees/<name>/gitdir` — a text file with `<abs-path-to-worktree>/.git`

When the same filesystem is reachable at two different absolute paths (host vs. container, with the host filesystem bind-mounted into the container at a different mount point), both files point to a path that doesn't exist on the other side, so `git status` fails until the user runs `git worktree repair`. Git 2.48 (Jan 2025) added `worktree.useRelativePaths`, which writes those two files with paths relative to each other. The `commondir` file (third worktree pointer) is already relative by default.

A live test in this investigation revealed a subtler constraint: the relative-path **format** is fully readable by older git (verified against the container's git 2.39 — `git status`, `git worktree list`, `git commit` all work when only the link files are converted). But `git worktree repair --relative-paths` (and any subsequent worktree mutation by a 2.48+ host) also sets `extensions.relativeWorktrees = true` in the repo's `.git/config`. From that moment, any git < 2.48 refuses to operate on the repo at all with `fatal: unknown repository extension found: relativeworktrees`. This is a deliberate safety lock, not an oversight: older git could otherwise write absolute-path worktrees into a repo configured for relative paths, creating an inconsistent state.

The implication: the workflow only functions if both host and container have git ≥ 2.48. A host-only opt-in actively *breaks* the container.

The user's concrete pain point is the `<repo>/.claude/worktrees/<name>` layout — a worktree nested inside the repo tree. With this layout, the relative offset between worktree and repo `.git/` is the same regardless of where the repo's root sits on disk, so relative paths trivially round-trip between host and container once both gits can speak the format.

## Goals / Non-Goals

**Goals:**

- Make nested-layout worktrees portable across host ↔ container without `git worktree repair`, regardless of which side created the worktree.
- Bump the container's `git` to ≥ 2.48 (target: 2.53.0 from Ubuntu 26.04 main archive) so it can both read and write relative-path worktrees, lifting the `extensions.relativeWorktrees` block.
- Document the host-side opt-in (`git config worktree.useRelativePaths true` + `git worktree repair --relative-paths` for existing worktrees) as the recommended workflow.
- Keep the existing repair-based workflow available as a fallback for hosts on git < 2.48 and for sibling-flattened layouts.

**Non-Goals:**

- Changing `run.sh`. The wrapper does not parse, rewrite, or validate worktree link files.
- Bumping Node from 20 to 22. NodeSource lets us continue tracking Node 20 LTS independently of the base image's archive Node, keeping this change focused on git. Node 22 (the LTS that Ubuntu 26.04 ships in its archive) is a separate decision worth its own change.
- Auto-applying `worktree.useRelativePaths` on the user's behalf. Users may legitimately want absolute paths.
- Supporting sibling-flattened worktrees without repair. Mounting `~/repo` and `~/repo-feature` as `/workspaces/repo` + `/workspaces/repo-feature` collapses the host's relative offset between them; relative paths cannot fix this without preserving the parent directory in the mount.
- Detecting worktrees inside `run.sh` and emitting a hint. Adds parsing surface for marginal benefit; the README change covers discovery.

## Decisions

### Decision: Document the host-side opt-in rather than auto-configure

**Choice:** README and spec recommend `git config worktree.useRelativePaths true` (per-repo or `--global`) and `git worktree repair --relative-paths` for existing worktrees. `run.sh` does not set this on the user's behalf.

**Rationale:** The link-file rewrite is a permanent change to the user's repo state. A one-line README instruction is reversible and discoverable; an automatic edit by `run.sh` would surprise users, and there is no reliable way to undo it on container exit (the wrapper exits before the user does any git work).

**Alternatives considered:**

- *`run.sh` runs `git worktree repair --relative-paths` automatically when it detects a worktree mount.* Rejected: requires probing the mount source to distinguish "repo containing a worktree" from "the worktree itself"; mutates host state without consent; older host git versions don't have the flag.
- *`run.sh` injects a one-shot `git config` into the container's local repo config.* Rejected: container-local config doesn't propagate to host operations, so the asymmetry remains.

### Decision: Switch base image to `ubuntu:26.04` LTS

**Choice:** Replace `FROM node:20-bookworm-slim@sha256:...` with `FROM ubuntu:26.04@sha256:...`. Install Node 20 LTS via NodeSource's apt repository (`deb.nodesource.com/node_20.x`, signed with a build-time-fetched keyring). Pin Node to an exact NodeSource package version via a `NODE_VERSION` ARG. `git` comes from Ubuntu's main archive at version 2.53.0 — well past the 2.48 threshold.

**Rationale:** Ubuntu 26.04 LTS (released April 2026) is the cleanest Debian-family path to git ≥ 2.48 — it's a single apt source, glibc-based (so AWS CLI v2 and `uv`'s gnu binary continue to work without changes), and the rest of the apt-installed tooling (`gh` repo, `glab` `.deb`, `tmux`, `jq`, etc.) ports unchanged because Ubuntu uses the same dpkg/apt machinery as Debian. NodeSource is the canonical mechanism for installing pinned Node versions on any Debian/Ubuntu base; it's already used by countless production Dockerfiles and signs its repo.

**Alternatives considered:**

- *Build git from source in a multi-stage Dockerfile.* Rejected: works, but adds ~2–3 minutes of compile time per arch, ongoing version-tracking burden (refresh sha256 on every git release), and a from-source binary that's harder to reason about (custom build flags, missing helpers) than the distro's package. The base-image swap is a smaller change in spirit even though it touches more lines.
- *Stay on Debian (`node:24-trixie-slim`) and apt-pin git from forky/sid.* Rejected: trixie's git is 2.47.3 — still below 2.48 by a hair. Cross-suite apt pinning works but is fragile: the next git release in forky might pull in a newer libc/libpcre transitively, breaking the rest of the trixie image. Adds a layer of operational risk for marginal "stays on Debian proper" benefit.
- *Switch to Alpine (`node:20-alpine3.22`+).* Rejected: Alpine 3.22 has git 2.49 via apk, but breaking AWS CLI v2 in the process — AWS does not ship a musl binary for v2 and there is no clean fix. Plus npm packages with native deps see musl prebuilds less often than glibc.
- *Stay on `node:20-bookworm-slim` and patch around it (e.g. strip `extensions.relativeWorktrees` from `.git/config` in the container).* Rejected: brittle (host's next worktree mutation re-sets the extension), surprising, and arguably worse than the original `git worktree repair` workflow it would be replacing.

### Decision: Pin Node via NodeSource rather than the base image

**Choice:** Use `apt install nodejs=${NODE_VERSION}` from NodeSource's `node_20.x` channel, with `NODE_VERSION` pinned exactly (e.g. `20.20.2-1nodesource1`). Update `NODE_VERSION` and the base-image digest together when refreshing the image.

**Rationale:** Ubuntu 26.04's archive ships Node 22 (Active LTS as of release), but tracks Ubuntu's snapshot rather than upstream LTS releases — bumping to a specific Node version means waiting for a `-security` archive update. NodeSource exposes every upstream Node minor/patch directly with quick turnaround. Sticking with Node 20 (the version the existing image used) keeps this change scoped to git, not Node.

**Alternatives considered:**

- *Use Ubuntu's archive `nodejs` package.* Rejected (here): jumps from Node 20 to Node 22 as a side effect of the image swap, mixing two separate version-bump concerns and breaking the "this change is about git" framing.
- *Continue with `node:` official image, just on a different Debian variant.* Rejected: no Debian variant of the official Node image satisfies the git ≥ 2.48 constraint without combining with one of the alternatives already rejected above.

### Decision: Split the spec requirement rather than mutate it in place

**Choice:** Modify the existing `Sibling worktrees supported` requirement to scope it explicitly to the sibling-flattened layout, and add a new `Nested worktrees portable via relative paths` requirement for the nested case.

**Rationale:** The two layouts have genuinely different semantics — sibling-flattened cannot avoid repair because the relative offset isn't preserved by the bind mount; nested can avoid repair because the offset *is* preserved. Conflating them in one requirement obscures the contract.

**Alternatives considered:**

- *Single requirement that covers both cases with conditional language.* Rejected: scenarios become harder to write and the testable contract gets vaguer.
- *Remove the sibling-flattened requirement entirely.* Rejected: it remains the only way to work across two repos that share branches, which is a real workflow.

## Risks / Trade-offs

- **[Risk] Host on git < 2.48 can't opt in to relative paths.** → Mitigation: README explicitly calls out the version requirement and keeps `git worktree repair` (no flag) documented as the fallback. macOS Homebrew users are typically on a current git; Apple's bundled `/usr/bin/git` can lag.
- **[Risk] Base-image swap breaks one of the apt-installed tools (`gh` repo, `glab` `.deb`, AWS CLI v2 binary, `uv` glibc tarball).** → Mitigation: all of those tools target glibc Linux generically (not a specific distro); Ubuntu 26.04 is glibc and uses the same dpkg machinery. Verify each tool runs (`gh --version`, `glab --version`, `aws --version`, `uv --version`) in the build acceptance step. Risk is low but worth explicit verification.
- **[Risk] NodeSource publishes a different Node 20 minor than expected, or rotates its signing key.** → Mitigation: pin `NODE_VERSION` exactly (`20.20.2-1nodesource1`-style); the apt install fails loudly if the version is missing. Keyring is fetched at build (same pattern as `gh`) — a rotation is detected by build failure, not a silent compromise.
- **[Risk] User configures `worktree.useRelativePaths=true` globally and then moves a worktree to a path with a different relative offset to its repo.** → Mitigation: pre-existing failure mode for any worktree (relative or absolute) — the user accepts that worktrees aren't free to relocate. Document the layout invariant in the README.
- **[Risk] `worktree.useRelativePaths` interacts unexpectedly with worktrees that have already been repaired with absolute paths.** → Mitigation: `git worktree repair --relative-paths` rewrites both link files in one shot; users who set the config without repairing existing worktrees see no change to existing worktrees (they keep absolute paths) and only new ones use relative — both states work, only newly-created or explicitly-repaired worktrees gain the portability property.
- **[Trade-off] The change closes the host↔container asymmetry only for the nested layout.** Sibling-flattened worktrees still need repair. We accept this because the nested layout is the common case (and is the layout the user is actually using) and the sibling layout has a structural reason it can't benefit.

## Migration Plan

1. Land the Dockerfile change and rebuild the image — `docker buildx build --platform linux/amd64,linux/arm64 -t claude-code:local ./claude-docker`. Run `claude-docker --help` (or any command that resolves the wrapper) to confirm the new image works. No user action needed for users who don't opt in to relative paths; existing repair-based workflow continues to work.
2. Land the README and spec updates documenting the opt-in.
3. Users who want the new behavior run, on the host:
   ```
   git config --global worktree.useRelativePaths true       # future worktrees
   git worktree repair --relative-paths <existing-wt-path>  # existing worktrees, one-shot
   ```
4. Rollback: `git config --unset worktree.useRelativePaths`, `git config --unset extensions.relativeWorktrees` (or `git config --remove-section extensions`) on the repo, and `git worktree repair` (no flag) to rewrite link files back to absolute paths. The Dockerfile change is a pure version bump and doesn't need to be rolled back from the user side.

## Open Questions

- *(none — base-image swap to ubuntu:26.04 + NodeSource resolves the constraints cleanly without from-source builds or apt pinning.)*
