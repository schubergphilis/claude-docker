# Security

[← Back to the README](../README.md)

## Threat model

The container narrows blast radius vs. running `claude --yolo` on the host, but it is **not** a full sandbox:

- **Protected:** host filesystem outside your passed workspaces, host `~/.aws/credentials` (long-lived keys), host AWS/glab config dirs are read-only from inside (container can't persist changes back).
- **Exposed (per session):** your passed workspaces are read-write (unless `--ro`), and that is not a one-way boundary: files in a workspace that the host later runs are ordinary writable files from inside — git hooks under `.git/hooks/` (and a `core.hooksPath` pointing inside the workspace, e.g. husky's `.husky/`), `.envrc`, Makefiles, editor task configs — so a session can reach host code execution the next time you run git or those tools on the host. Review changes to them before running them on the host, and use `--ro` for untrusted repos; host credentials when opted in — short-lived AWS SSO bearer tokens (`~/.aws/sso/cache`), the glab config token, `~/.terraform.d/credentials.tfrc.json`, and `GITLAB_TOKEN` / `TF_TOKEN_app_terraform_io` / `AWS_*` / `AZURE_DEVOPS_EXT_PAT` env vars are all readable inside the container (the Azure DevOps PAT with whatever scope you minted it with — scope it to the org and the minimum rights, and keep it short-lived); under `--gh-direct` (but **not** plain `--gh`, see [GitHub auth proxy](auth.md#github-auth-proxy)), the real `GH_TOKEN` is readable inside the container too; under `--registry`, the **full contents** of mounted `~/.npmrc` / `pip.conf` (and forwarded `*_TOKEN` / `UV_INDEX_*_PASSWORD` env) are readable — and those files can hold tokens for registries beyond the one you intended (`~/.netrc` is deliberately not mounted, see [Private package registries](auth.md#private-package-registries)); full outbound network with no egress filtering.
- **GitHub via the proxy (`--gh`):** the real token itself no longer reaches the agent container — the biggest prior exposure for this flag is gone. What remains is _live capability_: a compromised session can still act on GitHub through the sidecar for the life of the session, bounded by its policy (default: no repo deletion, extensible via `CLAUDE_DOCKER_GH_POLICY`) and recorded in its audit log if you capture it (`docker logs <sidecar-name>`) before teardown. The sidecar is a policy point and a record, not a guarantee that a compromised session can't act on GitHub at all.
- **Exposed (cross-session):** the persistent `claude-code-root` and `claude-code-home` named volumes hold the Claude OAuth token, in-container `gh` / `glab` / `terraform login` state, `az devops configure` defaults under `~/.azure`, shell history, and conversation history. `claude --resume` can replay sessions from **any** past workspace — see [Resuming sessions across workspaces](../README.md#resuming-sessions-across-workspaces). Skipped under `--ephemeral`.
- **Persistence (cross-session):** the same volumes also carry a compromise _forward_. Files a session writes under `/root` that later sessions execute or load — git global config (`~/.gitconfig`: `core.fsmonitor`, `core.sshCommand`, aliases), shell rc files (`~/.bashrc`, `~/.profile`), Claude Code hooks in `~/.claude/settings.json`, and Claude's own instructions (auto-memory under `~/.claude/projects/*/memory/`, a `~/.claude/CLAUDE.md` when the host has none to mount read-only over it, and any `agents/`, `commands/` or `skills/` not mounted from the host) — run or are loaded again in every later session, including one launched with `--aws` / `--glab` / `--tfe` / `--gh-direct` (whose credentials they can then read) or `--gh` (whose live GitHub capability they can then use). A prompt-injected session with no credential flags is therefore not contained to that session. The `PATH` ordering in the image only stops a dropped binary from shadowing a system one; it does nothing about these files. Run untrusted repos with `--ephemeral`; don't start a credentialed session on the persistent volumes after an untrusted one without first clearing them (`docker volume rm claude-code-root claude-code-home`). Keeping a `~/.claude/settings.docker.json` re-seeds `settings.json` at every start, which closes the hooks path but not the others. For a prompt injection, the instruction files are the most direct way to carry forward: no code has to run, the next session simply reads them.
- **Instruction files are trusted, unverified input:** the host config items in [Host config parity](usage.md#host-config-parity) — `agents/`, `skills/`, `commands/`, `CLAUDE.md` from `~/.claude` or the `--claude-dir` target — are mounted as-is, with no signature or hash check, and `statusline-command.sh` is **executed** inside the container. Read-only stops the container writing back; it does not prove the files are the ones you approved. A skill or agent definition is instructions to a model with a shell, so anything that can edit those files on the host can steer a `--yolo` session. A workspace's own `CLAUDE.md` / `.claude/` is the same kind of input, arriving through the workspace mount: treat an untrusted repo as untrusted instructions, and use `--ephemeral --ro` with no credential flags (see [Session flags](../README.md#session-flags)).
- **Runtime code-fetch:** these fetch and execute code from public sources on first use. Under `--yolo`, a prompt-injected workspace can trigger any of them.
  - `npx`: npm packages.
  - `pnpm dlx`, also reachable as `pnpx`, `pnx` and `pn dlx`: running a package adds nothing beyond `npx`. Since pnpm 12, though, naming a package manager or runtime provisions the real thing: `pnx node@22`, `pnx deno@2`, `pnx bun@1.3.0`, `pnx yarn@4` and `pnx npm@11` fetch and execute that release, a **different, image-unpinned** runtime whose version the caller, or a `devEngines.runtime` / `packageManager` field in the workspace, selects. pnpm resolves these through npm's trusted package-manager registries and checks an npm-published one against npm's signature for that exact version, so provenance is verified even though the image pins nothing. There is no refusal switch like `GOTOOLCHAIN=local`. Unlike `tfenv`, what it downloads **persists**: it lands in `~/.local/share/pnpm/package-manager-store` and `~/.cache/pnpm`, inside the `claude-code-root` named volume, and later sessions reuse it.
  - `uvx`: PyPI packages. The image had no Python runtime before it.
  - `tfenv` (`tfenv install`, or the first `terraform` call, which auto-installs): HashiCorp releases from `releases.hashicorp.com`. The downloaded `terraform` is intentionally **not** sha256-pinned in the image; versions are project-pinned via `.terraform-version`, so the image stays neutral on version policy.
  - Go (`go build` / `go install` / `go run`): modules from `proxy.golang.org`, checksum-verified against the pinned `go.sum` and, for new modules, the public `sum.golang.org` transparency log. Because `GOTOOLCHAIN` is left at its default `auto`, a `go.mod` that requires a newer Go than the pinned `GO_VERSION` downloads that toolchain, signed and checksummed by the same module machinery. The image's Go pin is therefore a floor, not a ceiling; set `GOTOOLCHAIN=local` in the container to refuse the download and fail loudly instead.
- **Private registries (`--registry`):** this _narrows_ where the package managers resolve packages — pointing `uv` / `pnpm` / pip at a curated private feed instead of public npm/PyPI — which can reduce dependency-confusion exposure, but only as much as your host config and the feed's upstream setup dictate. It is registry-resolution config, **not** network egress filtering: `npx`, `git+https` installs, `curl`, and every other egress path are unaffected, and `--yolo` runtime code-fetch (above) still reaches whatever the resolved feed serves. Treat it as supply-chain hygiene, not a network boundary.
- **Custom model endpoint (`--api`):** the endpoint receives **all prompt content** — every file, command output, and tool result the agent reads — plus the forwarded token. Only point it at a gateway you trust with your code. `CLAUDE_DOCKER_API_CA` is trusted system-wide, for all TLS in the container, not only the gateway.
- **Private CA under `--az` (`CLAUDE_DOCKER_AZ_CA`):** installed into the system trust store, so like `CLAUDE_DOCKER_API_CA` it is trusted for every TLS connection in the container, not only the Azure DevOps Server.
- **If a session is compromised:** assume exfiltration already happened. It had full network egress, with or without `--egress-lock`; under `--egress-lock` the saved egress log shows which hosts it reached. Then: rotate the host sessions for every flag that was passed — `glab auth login`, `aws sso login`, `terraform login`, and revoke the Azure DevOps PAT under _User settings → Personal access tokens_ for `--az`; under `--registry`, re-run `aws codeartifact login` / rotate the npm·PyPI registry tokens exposed via the mounted `~/.npmrc` / `pip.conf`. **GitHub is different under `--gh`:** the real token never entered the container, so there's no token to rotate on that basis alone — but review what the session _did_ through the proxy during its lifetime (the sidecar's audit log helps, if you captured it via `docker logs` before teardown), and revert any resulting GitHub-side actions. If the token itself may be exposed (a `--gh-direct` session, a version predating this proxy, or any doubt), **revoke** it — not merely `gh auth logout`/`login`, which only clear local state and leave the issued token valid at GitHub: revoke the _GitHub CLI_ authorization under _Settings → Applications → Authorized OAuth Apps_, or delete the PAT under _Settings → Developer settings_ if you used one. In all cases: revoke the Claude OAuth credential, and clear the named volumes (`docker volume rm claude-code-root claude-code-home`) to flush in-container auth state and cross-workspace conversation history that `claude --resume` could otherwise replay.

### Hardening

**Not applied:**

- read-only root filesystem
- user-namespace remapping
- custom seccomp profile (Docker's default is in use)
- network egress filtering (`--egress-lock` restricts model traffic only, see [API egress lock](auth.md#api-egress-lock))
- resource limits

**Applied at runtime:**

- `--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_READ_SEARCH`. The four added caps are held only during entrypoint setup. The kernel clears them from the effective / permitted / ambient sets when the entrypoint drops UID 0 → host UID (the bounding set keeps them but is inert under `no-new-privileges`), so claude itself runs with no usable capabilities.
- `--security-opt no-new-privileges`.
- `--init`: tini reaps subprocess zombies; `runuser` would otherwise be PID 1.
- The container starts as root and drops to the host user before exec'ing claude (see [File ownership](usage.md#file-ownership)).
- The Docker default seccomp profile.
- Scoped workspace bind-mounts, and tmpfs masks over non-opted-in credential paths.

**Applied at build time:**

- Pinned base image digest.
- sha256-verified downloads where the ecosystem supports it: uv, glab, AWS CLI, tfenv source archive, Go tarball, azure-devops extension wheel.
- `nodejs` and `task` pinned by version alone, from a signature-verified apt repo. There is no committed hash, but apt checks the repo's signed index and the package digests it carries.
- `azure-cli-core` and all its transitive deps installed from a hash-locked `pins/az-requirements.txt` (`--require-hashes`).
- npm packages (npm itself, claude-code, openspec, pnpm) pinned by version with `--ignore-scripts`, not sha256-verified. A compromised npm registry serving a malicious tarball at the pinned version would not be caught at build time.
- Lifecycle scripts: claude-code and pnpm ship their native binary in a per-arch optional dependency and are unusable until their own install script links it. The build runs exactly those two scripts by hand (claude-code's `install.cjs`, pnpm's `install.js`) and asserts the result; the Dockerfile names them with the conditions they're held to. No other package's, or transitive dependency's, lifecycle script ever runs.
- CI scans the built image for **known** vulnerabilities in its OS and language packages and fails the build on a HIGH or CRITICAL finding that upstream has already fixed. Findings with no fix yet are reported but do not fail, and accepted ones carry a mandatory expiry (see [Image vulnerability scanning](#image-vulnerability-scanning)). A green build means no *fixable* high-severity CVE, not an absence of known CVEs.

## Image vulnerability scanning

CI scans the built image for **known** vulnerabilities with [Trivy](https://trivy.dev), across the whole image filesystem: the Ubuntu base image's system packages, the pinned CLIs, and their transitive dependencies. This is a different question from the one [`update_pins.py`](../update_pins.py) answers — that reports when a *newer* version exists, while a pin can sit on the newest release and still carry a disclosed CVE. It is also a different question from the `npm audit signatures` check in [Updating pinned tool versions](maintenance.md#updating-pinned-tool-versions), which establishes that a tarball came from npm's keyring, not that the code inside it is free of known vulnerabilities.

Each scan runs twice over the same image, with one policy:

| Finding | Effect |
| --- | --- |
| HIGH or CRITICAL, upstream fix available | **fails the build** |
| HIGH or CRITICAL, no fix available yet | reported in the job log, does not fail |
| MEDIUM and below | not reported at this threshold |

Only fixable findings gate, because only those are actionable: an unfixed upstream CVE can't be resolved by whoever opens the next unrelated PR, and blocking on one would hold a required check red for every contributor until somebody silenced it. When Ubuntu does publish the fix, the same finding becomes blocking on its own.

The scan is a **step in the `Docker build (validate, no push)` job**, not a check of its own. That job is the only one whose local Docker daemon holds the image the build step loaded, and `main`'s ruleset requires exactly the `Validate` and `Docker build (validate, no push)` contexts — so a separate job would report a status that gates no merge until someone edits the ruleset. The practical consequence: a red `Docker build (validate, no push)` can mean a broken Dockerfile, a failing smoke cell, **or** a CVE. The step names in the job log say which.

To accept a finding you can't fix yet, add it to [`.trivyignore`](../.trivyignore) with a reason and an expiry date:

```
# ubuntu has no fixed package yet; revisit at the next base-image bump
CVE-2026-12345 exp:2026-12-01
```

Both are mandatory, and [`tests/test_trivyignore.py`](../tests/test_trivyignore.py) is what makes them so — Trivy itself accepts an entry with no expiry and then suppresses it forever, which is how an accepted risk becomes a forgotten one. Past the expiry Trivy stops suppressing and the finding gates again. Suppression is per-CVE; lowering the scan's severity threshold or dropping the gate step is not the same decision as accepting one finding, and is not an accepted-risk mechanism.

A weekly run scans `main` on the same terms: [`image-scan.yml`](../.github/workflows/image-scan.yml) fires every Monday (and on demand via _Run workflow_), rebuilds the image — nothing publishes it to a registry, so there is nothing to pull — and applies the identical policy, so it reports what the next PR will be blocked by. It covers the case a PR scan structurally cannot: a CVE disclosed against an image whose pins never moved. **A failing run is the only notification** — nothing opens an issue and nothing uploads a report, which keeps the workflow's permissions at `contents: read`.
