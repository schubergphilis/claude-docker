# Maintenance

[← Back to the README](../README.md)

## Updating pinned tool versions

`uv`, `glab`, `aws-cli`, and `tfenv` are downloaded directly from GitHub/GitLab/vendor sites rather than from a language package registry, so nothing else verifies the bytes. Each is pinned to a version **and** a per-architecture sha256 that the Dockerfile checks (`sha256sum -c`) before installing. The npm-installed tools (`claude-code`, `openspec`, `pnpm`) are pinned by version only — `npm install` already verifies the tarball against the registry's `dist.integrity`, and CI additionally runs `npm audit signatures`. Those checks are about *provenance* — where the bytes came from. Whether the pinned version has a disclosed CVE is a separate question, answered by [Image vulnerability scanning](security.md#image-vulnerability-scanning).

The pins live in version-controlled fragments under [`pins/`](../pins/), one `pins/<tool>.env` per tool, which the Dockerfile `COPY`s and sources at build time — so `docker build` is reproducible from the committed files.

Refresh them with [`update_pins.py`](../update_pins.py) (a single stdlib-only Python file, run via `uv`):

```bash
uv run update_pins.py                      # refresh all tools (per-tool soak)
uv run update_pins.py --soak 14            # one 14-day soak window for every tool
uv run update_pins.py --block-major-bumps  # stay within each tool's current major
uv run update_pins.py --pin uv=0.12.3      # pin one tool to a specific version
```

For each tool it selects the newest stable version older than that tool's soak window, downloads the `amd64` and `arm64` artifacts, computes their sha256s, and rewrites `pins/<tool>.env`. The soak window gives a release time to be vetted (and a bad one pulled) before it enters the image. The window is 7 days for every tool except `claude-code`, which uses 1 day. Claude Code ships almost daily and most of its users update within hours, so a bad release is found and pulled within a day, and a 7-day pin only leaves the image behind. `--soak` sets one window for every tool in that run, `claude-code` included. The script prints a report — each `old → new` bump with its age, a `⬆ MAJOR` marker on major-version jumps, `held` lines for versions still inside the soak window, and `⚠` reminders for the manual pins — then review the diff, build to test, and commit. By default a major-version bump is taken once it has soaked; `--block-major-bumps` keeps a run within each tool's current major. Set `GITHUB_TOKEN` (or `GH_TOKEN`) to avoid GitHub's unauthenticated rate limit.

The script also has two listing modes that exist for CI rather than for you: `--list-tools` prints one row per pinned tool with the command that asks it its version and the rule for reading a version out of the reply, and `--list-npm-tools` does the same for the npm subset. CI's `Docker build` job runs every `--list-tools` probe against the image it just built and fails if a tool reports anything other than its pin — a successful install says nothing about whether the executable actually runs, and until this existed only `claude-code` was checked. Because the tool list and the probes come from the script, adding a tool to `pins/` extends that coverage without editing a workflow file.

A weekly GitHub Actions run does the same thing unattended: [`pins-updater.yml`](../.github/workflows/pins-updater.yml) fires every Monday (and on demand via _Run workflow_, where you can override the soak window or ask for `--block-major-bumps`), runs the same script, and — if any pin moved — force-pushes the `bump/pins` branch and opens (or refreshes) a single PR carrying the script's full report. One long-lived branch on purpose: a stale pins PR proposes versions that the next refresh has already superseded, so the newest run replaces the open PR rather than stacking another one beside it. The workflow invokes the script as `python3 update_pins.py` on the runner's preinstalled interpreter — it is stdlib-only, so there is nothing for `uv` to resolve and no toolchain to install first. Review the diff and let CI build the image before merging; the manual pins the report flags under `⚠ needs your eyes` still need a separate, hand-written commit.

> **CI on the automated PR — set `PINS_UPDATER_TOKEN` before enabling this.** Without that secret the PR is opened with the job's `GITHUB_TOKEN`, and GitHub deliberately does **not** trigger `pull_request` workflows for those. Since `main`'s ruleset requires the `Validate` and `Docker build (validate, no push)` checks, they never report and the PR **can't be merged** — not merely "unverified" — until a human pushes an empty commit or closes and reopens it. Add a fine-grained PAT scoped to this repo with `contents: write` + `pull requests: write` (or a GitHub App token) as the `PINS_UPDATER_TOKEN` repo secret and the workflow uses it instead, so CI runs on the PR as it would for a human.

`nodejs` (from NodeSource's signed apt repo), the Go toolchain, and the `ubuntu` base-image digest are pinned manually: the script reports base-digest drift and how the Go pin compares to the latest stable release, but does not rewrite either, since moving the base OS is a deliberate, separately-reviewed change. Go stays manual for a different reason — go.dev's release feed carries no publish dates, so the soak window can't be evaluated from it; the pin lives in the Dockerfile as `ARG GO_VERSION` plus a per-arch sha256, and the comment above it carries the exact `curl | jq` to read the new version and both hashes when bumping.

The [GitHub auth proxy](auth.md#github-auth-proxy) sidecar's Caddy image is pinned manually too, but lives outside this whole mechanism: the digest is a default in `run.sh` (`CLAUDE_DOCKER_PROXY_IMAGE`), not a file under `pins/`, and `update_pins.py` never touches it. That's deliberate — a Caddy upgrade can change Caddyfile directive semantics, i.e. the security-critical config this feature generates, so bumping it means reading the changelog and validating the generated Caddyfile against the new version by hand, not taking an automated version bump on faith.

## CI smoke tests

The container's runtime behaviour — privilege-drop, capability set, credential
isolation, file ownership — is exercised by a smoke harness
([`smoke/smoke.sh`](../smoke/smoke.sh) + [`smoke/assert-in-container.sh`](../smoke/assert-in-container.sh)).
It runs in CI on **Linux** on every change (in the
`docker-build` job, reusing the built image), across a matrix of cells: host UID
1000 / 501 / 0, cold and warm volumes, the `--aws` / `--glab` / `--tfe` opt-ins
(singly and combined), `--ephemeral`, and `--ro`. Most of the container's
behaviour lives inside Docker's Linux VM and is identical regardless of host OS,
so Linux CI covers the bulk of it.

Run a cell locally against a built image:

```bash
IMAGE=claude-code:local bash smoke/smoke.sh --uid="$(id -u)" --optins=aws,glab,tfe
```

The GitHub auth proxy sidecar (see [GitHub auth proxy](auth.md#github-auth-proxy)) has its own harness, [`tests/gh-proxy-integration.sh`](../tests/gh-proxy-integration.sh): it drives `run.sh` end-to-end against a mock GitHub upstream, credential-free and CI-runnable, since `smoke.sh` never invokes `run.sh` and CI has no real GitHub credentials to test against.

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

- Run the smoke cells on macOS: `IMAGE=claude-code:local bash smoke/smoke.sh --uid="$(id -u)" --volstate=warm` and `… --ro=1` and `… --optins=aws,glab,tfe` — the entrypoint must reach the dropped process with **no spurious `entrypoint: WARN`** despite the `:ro` mounts under `/root`.
- File ownership round-trips to the host user and is editable without `sudo` on a real `~/repo` bind mount.
- macOS Keychain `gh` flow: `--gh` with no `GH_TOKEN`/`GITHUB_TOKEN` exported falls back to `gh auth token`; in-container `gh` is authenticated.
- Real AWS SSO (`--aws`) and Terraform Cloud (`--tfe`) reach their endpoints from inside the container via the mounted config.
- `--iterm` (`tmux -CC`) renders native panes (control mode can't be asserted headlessly).
- GitHub auth proxy, real credentials: `gh api /user` through the sidecar (`--gh`) returns your real identity while `echo $GH_TOKEN` in the container still shows the placeholder; clone and push a private repo over HTTPS with no credential prompt; `git lfs pull` succeeds through the proxy (batch call on `github.com` gets the injected header, object transfer hits pre-signed hosts unmodified); the statusline tag reads `gh` for a proxied session and `gh-direct` for `--gh-direct`.
- GitHub auth proxy, platform parity _(not macOS-specific — grouped here because it's likewise outside the CI harness)_: under podman, sidecar `network create` / `inspect` (reading the sidecar IP) / `cp` (CA extraction) / `--add-host` behave like their docker equivalents; from Git Bash on Windows, the staged Caddyfile and CA-certificate mounts reach `podman.exe`/`docker.exe` with intact paths (same `hostpath()` translation as the rest of the wrapper).
