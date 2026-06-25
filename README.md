# claude-docker

Run Claude Code in a container that inherits your setup but not your filesystem. Workspace access is scoped to the directories you pass in; your statusline, skills, agents, and slash commands ride along as read-only bind-mounts. CLI tools are preinstalled (`gh`, `glab`, `aws`, `openspec`, `uv`, `pnpm`, `tfenv`, `git-lfs`) — language runtimes are not: `tfenv` and `uv` fetch your project-pinned Terraform / Python on demand. Host credentials (`gh`, `glab`, `aws`, `tfe`) are opt-in per flag; nothing leaks in by default.

The VCS and cloud CLIs (`gh`, `glab`, `aws`) need a flag to see host credentials — see [Credential opt-in](#credential-opt-in). The rest work out of the box.

## Install

```bash
# Build the image from your checkout (one-time; rerun after Dockerfile or tool pins change)
docker build -t claude-code:local ./claude-docker

# Put on your PATH (create ~/bin if it doesn't exist)
mkdir -p ~/bin
ln -s "$(pwd)/claude-docker/run.sh" ~/bin/claude-docker
```

## Usage

```bash
claude-docker                             # current dir as workspace
claude-docker ~/repo-a ~/repo-b           # multi-workspace
claude-docker --yolo ~/repo               # alias for --dangerously-skip-permissions
claude-docker ~/repo -- --resume          # any claude flag after --
```

`claude-docker --help` (or `-h`) prints every wrapper flag with a one-line explanation — the canonical reference.

### Credential opt-in

**Credentials are off by default.** No AWS / GitHub / GitLab / Terraform Cloud config, tokens, or env vars reach the container unless you explicitly opt in:

| Flag         | Effect |
|--------------|--------|
| `--aws`      | Mount `~/.aws/config` and `~/.aws/sso/` read-only and forward `AWS_PROFILE` / `AWS_REGION` / `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` / `AWS_SESSION_TOKEN`. `~/.aws/credentials` (long-lived keys) and `~/.aws/cli/cache/` are **not** mounted. |
| `--gh`       | Forward `GH_TOKEN` / `GITHUB_TOKEN`; if neither is set on the host, the wrapper extracts a token via `gh auth token` (host keychain) and forwards that. Unmasks in-container `gh auth login` state persisted in `claude-code-root` — without this flag, `/root/.config/gh/` is hidden by a tmpfs overlay so a prior login can't leak into a non-opted-in session. |
| `--glab`     | Mount the platform-appropriate `glab-cli` config dir read-only (macOS: `~/Library/Application Support/glab-cli`, Linux: `~/.config/glab-cli`) and forward `GITLAB_TOKEN`. Unmasks in-container `glab auth login` state — without the flag, `/root/.config/glab-cli/` is hidden by a tmpfs overlay. |
| `--tfe`      | Mount `~/.terraform.d/credentials.tfrc.json` read-only when present and forward `TF_TOKEN_app_terraform_io`. Targets `app.terraform.io` (HCP Terraform) only — self-hosted Terraform Enterprise hostnames and other `TF_TOKEN_<host>` variables are not forwarded. Unmasks in-container `terraform login` state — without the flag, `/root/.terraform.d/` is hidden by a tmpfs overlay. See [Terraform Cloud workflow](#terraform-cloud-workflow). |

Combine as needed: `claude-docker --aws --gh ~/repo`.

### Session flags

| Flag            | Effect |
|-----------------|--------|
| `--ephemeral`   | Skip the persistent named volumes. No in-container auth state, shell history, or conversation history persists across runs. |
| `--ro`          | Mount every workspace read-only. Prevents the agent from modifying your code. |

`--ro` does **not** block credential flags or restrict network egress — for an isolated review session, combine `--ephemeral` and `--ro` and pass no credential flags:

```bash
claude-docker --ephemeral --ro ~/untrusted-repo
```

For `--iterm` / `--tmux` (teammate split panes), see [Split-pane agent teams](#split-pane-agent-teams). In-container YOLO narrows the blast radius compared to running on the host, but see [Threat model](#threat-model) for what it does and doesn't protect.

### Resuming sessions across workspaces

Conversation history persists in the shared `claude-code-home` volume (skipped under `--ephemeral`), so `claude --resume` followed by `Ctrl+A` lists sessions from every workspace you've ever used — not just the one you're currently in.

## Host config parity

On every run, these items are dereferenced (symlinks resolved) and bind-mounted read-only into the container at the equivalent `/root/.claude/` path:

| Item                              | Purpose                             |
|-----------------------------------|-------------------------------------|
| `~/.claude/agents/`               | custom agent definitions            |
| `~/.claude/skills/`               | custom skills                       |
| `~/.claude/commands/`             | slash commands                      |
| `~/.claude/CLAUDE.md`             | global preferences (`gprefs`)       |
| `~/.claude/statusline-command.sh` | statusline renderer                 |

For `settings.json`, maintain a dedicated `~/.claude/settings.docker.json` (any valid Claude `settings.json` schema) — it's bind-mounted at `/root/.claude/settings.json` when present. Keeping it separate from your host `settings.json` avoids dragging macOS-only keys (`sandbox`, `env.SSL_CERT_FILE`, `enabledPlugins`) or host-filesystem `hooks` into the container. See [`examples/settings.docker.json`](examples/settings.docker.json) for a starting point.

### Alternate Claude config dirs (`--claude-dir`)

If you keep more than one host Claude config (e.g. a personal `~/.claude/` and a work-only `~/.claude-work/`), point the wrapper at the one you want with `--claude-dir=PATH` or the `CLAUDE_DOCKER_CONFIG_DIR` env var:

```bash
claude-docker --claude-dir=~/.claude-work ~/repo
CLAUDE_DOCKER_CONFIG_DIR=~/.claude-work claude-docker ~/repo
```

The chosen dir takes the place of `~/.claude` for every item in the parity table above (agents, skills, commands, `CLAUDE.md`, statusline, `settings.docker.json`).

### Git identity

`user.name` and `user.email` from your global git config (`~/.gitconfig`) are forwarded automatically as `GIT_AUTHOR_NAME`/`GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_NAME`/`GIT_COMMITTER_EMAIL` so in-container `git commit` works out of the box with your real identity — no `git -c user.email=...` dance, no wrong-author commits. Not gated by a flag: identity is already public on every commit you've made. Signing keys, credential helpers, aliases, and hooks are NOT forwarded — those are host-specific (keychains, absolute paths) and would misfire inside the container.

### Statusline tag for active opt-ins

`run.sh` exports `CLAUDE_DOCKER_FLAGS` into the container with the comma-separated list of active opt-ins (`gh`, `aws`, `glab`, `tfe`, `ephemeral`, `ro`) and wraps the host statusline script so a yellow `docker:<flags>` tag is prepended to whatever your personal statusline renders. The variable is set by the wrapper for the statusline to read — not a user-tunable knob. `--yolo` / `--dangerously-skip-permissions` is not surfaced here — Claude Code's own mode indicator already makes it obvious. The wrapper is a no-op passthrough when no opt-ins are active, so your statusline looks unchanged on a plain `claude-docker ~/repo`.

The image sets `IS_SANDBOX=1` — historically required to let `--yolo` / `--dangerously-skip-permissions` work when claude ran as root. The entrypoint now drops to the host UID before exec'ing claude, so the root-user check no longer triggers in steady state; `IS_SANDBOX=1` remains as a safety net for the legacy `HOST_UID=0` fall-through path. OS-level hardening comes from `--cap-drop ALL` (with `CHOWN`, `SETUID`, `SETGID`, `DAC_READ_SEARCH` re-added for transient entrypoint use only), `--security-opt no-new-privileges`, the Docker default seccomp profile, `--init` (tini reaps subprocess zombies), and the bind-mount layout. See [File ownership](#file-ownership) and [Threat model](#threat-model) below.

## Auth model

Credentials are opt-in per run — see [Credential opt-in](#credential-opt-in) above for the per-flag effect, mounts, and env-var forwarding. The subsections below cover the two workflows that need more than a one-line table cell.

### AWS SSO flow (`--aws`)

Standard SSO usage works unchanged: `aws sso login --profile X && export AWS_PROFILE=X` on the host, then `claude-docker --aws`. The container reads the short-lived SSO bearer token from `~/.aws/sso/cache` via the read-only mount.

If you'd rather not mount `sso/cache` either, flatten to env vars after login:

```bash
aws sso login --profile X
eval "$(aws configure export-credentials --profile X --format env)"
claude-docker --aws ...
```

Container then uses `AWS_ACCESS_KEY_ID`/`SECRET`/`SESSION_TOKEN` and the SSO cache is not needed inside. Temp creds freeze at container start (~1h TTL).

### Terraform Cloud workflow

Standard usage targets `app.terraform.io` (HCP Terraform):

```bash
# One-time on the host: writes ~/.terraform.d/credentials.tfrc.json
terraform login app.terraform.io

# Per session
claude-docker --tfe ~/repo

# Inside the container, fetch the project-pinned terraform version
tfenv install            # reads .terraform-version, downloads from releases.hashicorp.com
terraform plan
```

The image ships `tfenv` (a pure-bash terraform version manager) and **does not** ship a pre-installed `terraform` binary version — versions are project-pinned (`required_version` / `.terraform-version`) and a single bundled version would drift against real workspaces. `tfenv install` writes terraform binaries under `/opt/tfenv/versions/`, which is **not** in the `claude-code-root` named volume; downloads do not persist across `docker run --rm` exits. Power users can build a child image (`FROM claude-code:local`) that runs `tfenv install <version>` at build time to bake a specific version into a derived image.

Token alternative: instead of (or in addition to) the credentials file, export `TF_TOKEN_app_terraform_io=<token>` on the host and `--tfe` will forward it. The terraform CLI honours both.

## File ownership

Files created inside the container appear on the host owned by the user who launched `claude-docker`, not by `root`. The wrapper forwards `HOST_UID` / `HOST_GID` and the in-container entrypoint creates a matching passwd entry and drops to it via `runuser` before exec'ing claude. Persistent state in the `claude-code-root` and `claude-code-home` named volumes is chowned on first start, so an existing volume from before this change is fixed up the next time you run `claude-docker`.

## Threat model

The container narrows blast radius vs. running `claude --yolo` on the host, but it is **not** a full sandbox:

- **Protected:** host filesystem outside your passed workspaces, host `~/.aws/credentials` (long-lived keys), host AWS/glab config dirs are read-only from inside (container can't persist changes back).
- **Exposed (per session):** your passed workspaces are read-write (unless `--ro`); host credentials when opted in — short-lived AWS SSO bearer tokens (`~/.aws/sso/cache`), the glab config token, `~/.terraform.d/credentials.tfrc.json`, and `GH_TOKEN` / `GITLAB_TOKEN` / `TF_TOKEN_app_terraform_io` / `AWS_*` env vars are all readable inside the container; full outbound network with no egress filtering.
- **Exposed (cross-session):** the persistent `claude-code-root` and `claude-code-home` named volumes hold the Claude OAuth token, in-container `gh` / `glab` / `terraform login` state, shell history, and conversation history. `claude --resume` can replay sessions from **any** past workspace — see [Resuming sessions across workspaces](#resuming-sessions-across-workspaces). Skipped under `--ephemeral`.
- **Runtime code-fetch:** `npx`, `pnpm dlx`, `uvx`, and `tfenv install` fetch and execute arbitrary code from public sources on first use — npm and PyPI for the package managers, `releases.hashicorp.com` for `tfenv install`. Under `--yolo`, a prompt-injected workspace can trigger these. `pnpm dlx` adds zero marginal blast radius vs the already-reachable `npx`; `uvx` is a *new* PyPI execution primitive (no Python runtime existed in the image before); `tfenv install` is a *new* HashiCorp release-channel execution primitive whose downloaded `terraform` binary is intentionally **not** sha256-pinned in the image (versions are project-pinned via `.terraform-version`, so the image stays neutral on version policy). Build-time installs of the CLIs themselves are pinned by version + sha256 where the ecosystem supports it (uv binary, glab .deb, AWS CLI, tfenv source archive), and by version only for npm-backed packages (claude-code, openspec, pnpm) — `--ignore-scripts` blocks lifecycle scripts at install time but does not protect against a compromised registry serving a malicious tarball at the pinned version.
- **If a session is compromised:** assume exfiltration already happened (full network egress). Then: rotate the host sessions for every flag that was passed (`gh auth refresh` / re-login, `glab auth login`, `aws sso login`, `terraform login`), revoke the Claude OAuth credential, and clear the named volumes (`docker volume rm claude-code-root claude-code-home`) to flush in-container auth state and cross-workspace conversation history that `claude --resume` could otherwise replay.

Hardening applied at runtime: `--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_READ_SEARCH` — the four added caps are held only during entrypoint setup and cleared from the effective / permitted / ambient sets by the kernel when the entrypoint drops UID 0 → host UID (the bounding set retains them but is inert under `no-new-privileges`), so claude itself runs with no usable capabilities; `--security-opt no-new-privileges`; `--init` (tini reaps subprocess zombies — `runuser` would otherwise be PID 1); container starts as root and drops to the host user before exec'ing claude (see [File ownership](#file-ownership)); the Docker default seccomp profile; scoped workspace bind-mounts; tmpfs masks over non-opted-in credential paths. Build-time: pinned base image digest, sha256-verified downloads where the ecosystem supports it (uv, glab, AWS CLI, tfenv source); npm packages (claude-code, openspec, pnpm) are version-pinned with `--ignore-scripts` but not sha256-verified — a compromised npm registry serving a malicious tarball at the pinned version would not be caught at build time. **Not** applied: read-only root filesystem, user-namespace remapping, custom seccomp profile (Docker's default is in use), network egress filtering, resource limits.

## Updating pinned tool versions

`uv`, `glab`, `aws-cli`, and `tfenv` are downloaded directly from GitHub/GitLab/vendor sites rather than from a language package registry, so nothing else verifies the bytes. Each is pinned to a version **and** a per-architecture sha256 that the Dockerfile checks (`sha256sum -c`) before installing. The npm-installed tools (`claude-code`, `openspec`, `pnpm`) are pinned by version only — `npm install` already verifies the tarball against the registry's `dist.integrity`, and CI additionally runs `npm audit signatures`.

The pins live in version-controlled fragments under [`pins/`](pins/), one `pins/<tool>.env` per tool, which the Dockerfile `COPY`s and sources at build time — so `docker build` is reproducible from the committed files.

Refresh them with [`update_pins.py`](update_pins.py) (a single stdlib-only Python file, run via `uv`):

```bash
uv run claude-docker/update_pins.py                      # refresh all tools (7-day soak)
uv run claude-docker/update_pins.py --soak 14            # wider soak window
uv run claude-docker/update_pins.py --block-major-bumps  # stay within each tool's current major
uv run claude-docker/update_pins.py --pin uv=0.12.3      # pin one tool to a specific version
```

For each tool it selects the newest stable version at least 7 days old, downloads the `amd64` and `arm64` artifacts, computes their sha256s, and rewrites `pins/<tool>.env` — the soak window gives a release time to be vetted (and a bad one pulled) before it enters the image. The script prints a report — each `old → new` bump with its age, a `⬆ MAJOR` marker on major-version jumps, `held` lines for versions still inside the soak window, and `⚠` reminders for the manual pins — then review the diff, build to test, and commit. By default a major-version bump is taken once it has soaked; `--block-major-bumps` keeps a run within each tool's current major. Set `GITHUB_TOKEN` (or `GH_TOKEN`) to avoid GitHub's unauthenticated rate limit.

`nodejs` (from NodeSource's signed apt repo) and the `ubuntu` base-image digest are pinned manually: the script reports base-digest drift but does not rewrite it, since moving the base OS is a deliberate, separately-reviewed change.

## Git worktrees

Git worktrees embed the path between the worktree and its repo's `.git/` in two link files. By default those paths are absolute, so a worktree created on the host breaks inside the container (and vice versa) because the same files sit at different absolute paths in each environment.

**No host config change needed.** For every workspace whose `.git/config` is a regular file (i.e. the main repo, not a worktree pointer), `claude-docker` overlays a container-only copy of `.git/config` that declares `extensions.relativeWorktrees = true` and `worktree.useRelativePaths = true`. The host's on-disk `.git/config` is never touched. Worktrees created inside the container therefore get relative paths, and those link files are then portable to the host without any opt-in.

This asymmetry is deliberate: the extension flag — when written into the host's `.git/config` — blinds tools that bundle an older libgit2 (notably `gitstatusd`, which powers the Powerlevel10k git prompt), because they refuse to open a v1 repo declaring an extension they don't know. Keeping the flag container-only sidesteps that.

To convert pre-existing absolute-path worktrees: from inside the container, run `git worktree repair --relative-paths <worktree-path>`. New worktrees added in the container get relative paths automatically.

**Trade-off:** container-side `git config` writes (e.g. `git remote add ...` writing to local config) land in the ephemeral overlay and are discarded when the container exits. Persistent `git config` edits should happen on the host.

**Fallback — `git worktree repair` (no flag), inside the container:**

```bash
git worktree repair
```

Use this when you passed a repo and a *sibling* worktree as separate workspace args (`claude-docker ~/repo ~/repo-feature`). Sibling-flattened mounts collapse the parent directory, so the relative offset between worktree and repo is not preserved by the bind mount and relative paths can't help.

**Caveats:**

- The overlay only applies to workspaces whose `.git` is a real directory (the main repo). If you mount only a worktree without its main repo, no overlay is created for it. Mount the main repo alongside if you need bidirectional worktree work.
- Relative paths assume the worktree's location relative to the repo's `.git/` is the same in both environments. Nested layouts (e.g. `<repo>/.claude/worktrees/<name>`) always satisfy this; moving a worktree to a totally different parent dir breaks both relative and absolute setups.

## Pasting images

`Cmd-V` to paste a clipboard image doesn't work inside the container — Claude Code reads the macOS clipboard via OS APIs that a Linux container can't reach. Workaround: save the image into any workspace you mounted (e.g. `Cmd-Shift-4` to Desktop, then move it into `~/repo`) and reference it from Claude with `@screenshot.png`.

## Split-pane agent teams

Claude's teammate feature needs tmux. Two modes:

| Flag       | Env var equivalent       | Effect |
|------------|--------------------------|--------|
| *(none — default)* | *(unset)*        | No tmux. Teammates fall back to Claude's **in-process** mode; cycle with Shift+Down. |
| `--tmux`   | `CLAUDE_DOCKER_TMUX=1`   | Plain tmux. Teammates = tmux splits in one terminal tab; switch with `C-b` + arrow keys. Any terminal. |
| `--iterm`  | `CLAUDE_DOCKER_TMUX=cc`  | `tmux -CC` (iTerm2 control mode). Teammates = **native iTerm2 panes/tabs**. macOS + iTerm2 only. |

The env vars are handy for `export` in your shell rc; the flags are handy for one-offs. Both modes need `teammateMode` set in `settings.docker.json` — see [`examples/settings.docker.json`](examples/settings.docker.json). The image already bakes in `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1`, so you don't need to add that env var yourself.

### iTerm2 tips for `cc` mode

- Launch from a tab that is **not** already inside a host `tmux -CC` session — nesting degrades the inner server to plain splits.
- iTerm2 → Settings → General → tmux → Attaching → **"When attaching, restore windows as:"** → `Tabs in the attaching window` keeps the gateway and Claude's content inside one iTerm2 window (default is `Native windows`, which spawns a separate window).
- iTerm2 → Settings → General → tmux → **"Automatically bury the tmux client session after connecting"** → hides the `** tmux mode started **` gateway tab on attach so only the Claude tab is visible. Retrieve the gateway later via Session → Buried Sessions if needed.
- The UTF-8 warning from earlier builds is resolved — the image sets `LANG=C.UTF-8` and `run.sh` passes `tmux -u`.

## Extending the image

When a project needs extra tooling (language runtimes, package managers, project-scoped CLIs) that doesn't belong in the base image, build a child image and reuse this wrapper via the `CLAUDE_DOCKER_IMAGE` env var — no need to fork `run.sh`.

In the child repo:

```dockerfile
# .claude-docker/Dockerfile
FROM claude-code:local
RUN ...   # add your extras here
```

```bash
#!/usr/bin/env bash
# claude-docker (project-root entrypoint)
set -euo pipefail
here=$(cd "$(dirname "$0")" && pwd)
IMAGE="claude-code-myproject:local"
docker build -t "$IMAGE" "$here/.claude-docker"
CLAUDE_DOCKER_IMAGE="$IMAGE" exec claude-docker "$@"
```

The child Dockerfile uses `FROM claude-code:local` (locally-built tag) — assumes the base has been built once on the host. Every wrapper flag (`--aws`, `--gh`, `--ephemeral`, `--ro`, `--iterm`, …) keeps working because the child script just exec's into this one with a different image tag.

Any extra package managers a child image installs (rustup, go, ruby, etc.) *add* to the runtime code-fetch surface noted under [Threat model](#threat-model) — they don't replace the existing `npx`/`pnpm dlx`/`uvx` primitives.

## CI smoke tests

The container's runtime behaviour — privilege-drop, capability set, credential
isolation, file ownership — is exercised by a smoke harness
([`smoke/smoke.sh`](smoke/smoke.sh) + [`smoke/assert-in-container.sh`](smoke/assert-in-container.sh)).
It runs in CI on **Linux** on every change to `claude-docker/**` (in the
`docker-build` job, reusing the built image), across a matrix of cells: host UID
1000 / 501 / 0, cold and warm volumes, the `--aws` / `--glab` / `--tfe` opt-ins
(singly and combined), `--ephemeral`, and `--ro`. Most of the container's
behaviour lives inside Docker's Linux VM and is identical regardless of host OS,
so Linux CI covers the bulk of it.

Run a cell locally against a built image:

```bash
IMAGE=claude-code:local bash claude-docker/smoke/smoke.sh --uid="$(id -u)" --optins=aws,glab,tfe
```

### Manual fallback checklist (macOS)

There is **no automated macOS CI job**: GitHub-hosted `macos-latest` runners
can't reliably provision a Docker daemon (the `vz` VM driver fails to boot under
the runner's nested-virtualization limits, and the `qemu` driver hits an upstream
Lima crash), so a hosted job can't even reach the assertions — and Colima's
file-sharing may not match Docker Desktop's anyway. The one behaviour unique to
macOS is **virtiofs collapsing `st_dev` across bind mounts**, which changes how
`entrypoint.sh`'s `-xdev` chown-prune treats the `:ro` mounts under `/root`
(see `entrypoint.sh:30-45`). Verify it by hand on a real Mac with Docker Desktop
before shipping changes to `entrypoint.sh` / `run.sh` / `Dockerfile`:

- Run the smoke cells on macOS: `IMAGE=claude-code:local bash claude-docker/smoke/smoke.sh --uid="$(id -u)" --volstate=warm` and `… --ro=1` and `… --optins=aws,glab,tfe` — the entrypoint must reach the dropped process with **no spurious `entrypoint: WARN`** despite the `:ro` mounts under `/root`.
- File ownership round-trips to the host user and is editable without `sudo` on a real `~/repo` bind mount.
- macOS Keychain `gh` flow: `--gh` with no `GH_TOKEN`/`GITHUB_TOKEN` exported falls back to `gh auth token`; in-container `gh` is authenticated.
- Real AWS SSO (`--aws`) and Terraform Cloud (`--tfe`) reach their endpoints from inside the container via the mounted config.
- `--iterm` (`tmux -CC`) renders native panes (control mode can't be asserted headlessly).

## Specs

Behavioural requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).
