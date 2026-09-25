# Security

[← Back to the README](../README.md)

## Threat model

The container narrows blast radius vs. running `claude --yolo` on the host, but it is **not** a full sandbox:

- **Protected:** host filesystem outside your passed workspaces, host `~/.aws/credentials` (long-lived keys), host AWS/glab config dirs are read-only from inside (container can't persist changes back).
- **Exposed (per session):** your passed workspaces are read-write (unless `--ro`); host credentials when opted in — short-lived AWS SSO bearer tokens (`~/.aws/sso/cache`), the glab config token, `~/.terraform.d/credentials.tfrc.json`, and `GITLAB_TOKEN` / `TF_TOKEN_app_terraform_io` / `AWS_*` / `AZURE_DEVOPS_EXT_PAT` env vars are all readable inside the container (the Azure DevOps PAT with whatever scope you minted it with — scope it to the org and the minimum rights, and keep it short-lived); under `--gh-direct` (but **not** plain `--gh`, see [GitHub auth proxy](auth.md#github-auth-proxy)), the real `GH_TOKEN` is readable inside the container too; under `--registry`, the **full contents** of mounted `~/.npmrc` / `pip.conf` (and forwarded `*_TOKEN` / `UV_INDEX_*_PASSWORD` env) are readable — and those files can hold tokens for registries beyond the one you intended (`~/.netrc` is deliberately not mounted, see [Private package registries](auth.md#private-package-registries)); full outbound network with no egress filtering **by default**. Under `--egress-allowlist`, only the allowlisted hosts are reachable, see [Egress allowlist](#egress-allowlist).
- **GitHub via the proxy (`--gh`):** the real token itself no longer reaches the agent container — the biggest prior exposure for this flag is gone. What remains is _live capability_: a compromised session can still act on GitHub through the sidecar for the life of the session, bounded by its policy (default: no repo deletion, extensible via `CLAUDE_DOCKER_GH_POLICY`) and recorded in its audit log if you capture it (`docker logs <sidecar-name>`) before teardown. The sidecar is a policy point and a record, not a guarantee that a compromised session can't act on GitHub at all.
- **Exposed (cross-session):** the persistent `claude-code-root` and `claude-code-home` named volumes hold the Claude OAuth token, in-container `gh` / `glab` / `terraform login` state, `az devops configure` defaults under `~/.azure`, shell history, and conversation history. `claude --resume` can replay sessions from **any** past workspace — see [Resuming sessions across workspaces](../README.md#resuming-sessions-across-workspaces). Skipped under `--ephemeral`.
- **Instruction files are trusted, unverified input:** the host config items in [Host config parity](workflows.md#host-config-parity) — `agents/`, `skills/`, `commands/`, `CLAUDE.md` from `~/.claude` or the `--claude-dir` target — are mounted as-is, with no signature or hash check, and `statusline-command.sh` is **executed** inside the container. Read-only stops the container writing back; it does not prove the files are the ones you approved. A skill or agent definition is instructions to a model with a shell, so anything that can edit those files on the host can steer a `--yolo` session. A workspace's own `CLAUDE.md` / `.claude/` is the same kind of input, arriving through the workspace mount: treat an untrusted repo as untrusted instructions, and use `--ephemeral --ro` with no credential flags (see [Session flags](../README.md#session-flags)).
- **Runtime code-fetch:** `npx`, `pnpm dlx`, `uvx`, `tfenv install`, and the Go toolchain fetch and execute arbitrary code from public sources on first use — npm and PyPI for the package managers, `releases.hashicorp.com` for `tfenv install`, `proxy.golang.org` for `go build` / `go install` / `go run`. Under `--yolo`, a prompt-injected workspace can trigger these. `pnpm dlx` — also reachable as `pnpx`, `pnx`, and `pn dlx`, the same primitive under four names — adds zero marginal blast radius vs the already-reachable `npx` **when it runs a package**, but since pnpm 12 it is more than that: naming a package manager or a runtime provisions the real thing, so `pnx node@22`, `pnx deno@2`, `pnx bun@1.3.0`, `pnx yarn@4` and `pnx npm@11` fetch and execute that release rather than installing an npm package that shares the name. That makes it a _new_ runtime-execution primitive in the same class as `tfenv install`: the image ships one pinned Node (`nodejs`) and one pinned Go, and this fetches a **different, image-unpinned** runtime whose version the caller — or a `devEngines.runtime` / `packageManager` field in the workspace — selects. pnpm resolves these through npm's trusted package-manager registries and verifies an npm-published one against npm's signature for that exact version before executing it, so provenance is checked even though the image pins nothing; there is no documented refusal switch equivalent to `GOTOOLCHAIN=local`. Unlike `tfenv install`, what it downloads **persists**: provisioned runtimes and package managers land in `~/.local/share/pnpm/package-manager-store` and `~/.cache/pnpm`, inside the `claude-code-root` named volume, so they survive `docker run --rm` and are reused by later sessions; `uvx` is a _new_ PyPI execution primitive (no Python runtime existed in the image before); `tfenv install` is a _new_ HashiCorp release-channel execution primitive whose downloaded `terraform` binary is intentionally **not** sha256-pinned in the image (versions are project-pinned via `.terraform-version`, so the image stays neutral on version policy). Go adds two such primitives: module downloads (checksum-verified against the pinned `go.sum` and, for new modules, the public `sum.golang.org` transparency log) and — because `GOTOOLCHAIN` is left at its default `auto` — the on-demand download of a _different_ Go toolchain when a project's `go.mod` requires one newer than the pinned `GO_VERSION`. That download is signed-and-checksummed by the same module machinery, but it does mean the image's Go pin is a floor, not a ceiling; set `GOTOOLCHAIN=local` in the container to refuse it and fail loudly instead. Build-time installs of the CLIs themselves are pinned by version + sha256 where the ecosystem supports it (uv binary, glab .deb, AWS CLI, tfenv source archive, Go tarball), by version alone from a signature-verified apt repo for `nodejs` and `task` (no committed hash, but apt checks the repo's signed index and the package digests it carries), and by version only for npm-backed packages (claude-code, openspec, pnpm) and for `azure-cli-core` from PyPI (its transitive deps resolve at build time; the `azure-devops` extension wheel itself is sha256-pinned) — `--ignore-scripts` blocks lifecycle scripts at install time but does not protect against a compromised registry serving a malicious tarball at the pinned version.
- **Private registries (`--registry`):** this _narrows_ where the package managers resolve packages — pointing `uv` / `pnpm` / pip at a curated private feed instead of public npm/PyPI — which can reduce dependency-confusion exposure, but only as much as your host config and the feed's upstream setup dictate. It is registry-resolution config, **not** network egress filtering (that is [`--egress-allowlist`](#egress-allowlist)): `npx`, `git+https` installs, `curl`, and every other egress path are unaffected, and `--yolo` runtime code-fetch (above) still reaches whatever the resolved feed serves. Treat it as supply-chain hygiene, not a network boundary.
- **Custom model endpoint (`--api`):** the endpoint receives **all prompt content** — every file, command output, and tool result the agent reads — plus the forwarded token. Only point it at a gateway you trust with your code.
- **If a session is compromised:** assume exfiltration already happened. Without `--egress-allowlist` it had full network egress. With it, exfiltration was limited to the allowlisted hosts, which still include the Anthropic API and every service whose credential you opted in to. Then: rotate the host sessions for every flag that was passed — `glab auth login`, `aws sso login`, `terraform login`, and revoke the Azure DevOps PAT under _User settings → Personal access tokens_ for `--az`; under `--registry`, re-run `aws codeartifact login` / rotate the npm·PyPI registry tokens exposed via the mounted `~/.npmrc` / `pip.conf`. **GitHub is different under `--gh`:** the real token never entered the container, so there's no token to rotate on that basis alone — but review what the session _did_ through the proxy during its lifetime (the sidecar's audit log helps, if you captured it via `docker logs` before teardown), and revert any resulting GitHub-side actions. If the token itself may be exposed (a `--gh-direct` session, a version predating this proxy, or any doubt), **revoke** it — not merely `gh auth logout`/`login`, which only clear local state and leave the issued token valid at GitHub: revoke the _GitHub CLI_ authorization under _Settings → Applications → Authorized OAuth Apps_, or delete the PAT under _Settings → Developer settings_ if you used one. In all cases: revoke the Claude OAuth credential, and clear the named volumes (`docker volume rm claude-code-root claude-code-home`) to flush in-container auth state and cross-workspace conversation history that `claude --resume` could otherwise replay.

Hardening applied at runtime: `--cap-drop ALL --cap-add CHOWN --cap-add SETUID --cap-add SETGID --cap-add DAC_READ_SEARCH` — the four added caps are held only during entrypoint setup and cleared from the effective / permitted / ambient sets by the kernel when the entrypoint drops UID 0 → host UID (the bounding set retains them but is inert under `no-new-privileges`), so claude itself runs with no usable capabilities; `--security-opt no-new-privileges`; `--init` (tini reaps subprocess zombies — `runuser` would otherwise be PID 1); container starts as root and drops to the host user before exec'ing claude (see [File ownership](workflows.md#file-ownership)); the Docker default seccomp profile; scoped workspace bind-mounts; tmpfs masks over non-opted-in credential paths. Build-time: pinned base image digest, sha256-verified downloads where the ecosystem supports it (uv, glab, AWS CLI, tfenv source, Go tarball, azure-devops extension wheel); npm packages (claude-code, openspec, pnpm) are version-pinned with `--ignore-scripts` but not sha256-verified — a compromised npm registry serving a malicious tarball at the pinned version would not be caught at build time. Two of those three ship a native binary in a per-arch optional dependency and are unusable until their own install script links it, so the build invokes exactly those two scripts by hand (claude-code's `install.cjs`, pnpm's `install.js`) and asserts the result; they are named in the Dockerfile with the conditions they're held to, and no other package's — or transitive dependency's — lifecycle script ever runs. CI additionally scans the built image for **known** vulnerabilities in its OS and language packages and fails the build on a HIGH or CRITICAL finding that upstream has already fixed; findings with no fix available yet are reported but do not fail, and accepted ones are recorded with a mandatory expiry (see [Image vulnerability scanning](#image-vulnerability-scanning)) — so a green build means no *fixable* high-severity CVE, not an absence of known CVEs. **Not** applied: read-only root filesystem, user-namespace remapping, custom seccomp profile (Docker's default is in use), network egress filtering by default (it is opt-in via `--egress-allowlist`), resource limits.

## Egress allowlist

`--egress-allowlist` makes network egress default-deny. It is opt-in. Without the flag, networking is unchanged.

```bash
export CLAUDE_DOCKER_EGRESS_ALLOW="registry.npmjs.org pypi.org files.pythonhosted.org"
claude-docker --egress-allowlist ~/repo
```

**How it works.** The agent container is attached only to a per-session network created with `--internal` (`claude-egress-<id>`). That network has no gateway, so a raw socket, a direct IP, or a DNS lookup has nowhere to go. A per-session squid forward proxy (`claude-egress-proxy-<id>`) sits on that network and on a normal one. The agent gets `http_proxy` / `https_proxy` (both spellings) pointing at it. HTTPS goes through `CONNECT`, so TLS stays end-to-end: the proxy sees hostnames, never request contents or tokens. The proxy is squid from this same image (installed from the Ubuntu archive), so there is no extra image to pull or pin. It runs as an unprivileged user with no capabilities. The agent container's capability set is unchanged.

**What is allowed** is the union of:

- the Anthropic API and login hosts: `api.anthropic.com`, `claude.ai`, `platform.claude.com`, `console.anthropic.com`;
- the hosts each credential opt-in you pass needs:
  - `--gh` / `--gh-direct`: `github.com`, `api.github.com`, `uploads.github.com`, `codeload.github.com`, `raw.githubusercontent.com`, `objects.githubusercontent.com`, `release-assets.githubusercontent.com`
  - `--glab`: `gitlab.com`
  - `--tfe`: `app.terraform.io`
  - `--aws`: `.amazonaws.com`. This is broad by necessity (STS, SSO-OIDC and every regional endpoint live there), and it includes S3, so an attacker-owned bucket is reachable.
  - `--az`: `.dev.azure.com` (`dev.azure.com` and its `vssps` / `vsrm` / `feeds` service hosts), `.visualstudio.com` (legacy org URLs), and the host of `AZURE_DEVOPS_ORG_URL` if set (an on-prem Server)
  - `--api`: the host of `ANTHROPIC_BASE_URL`, if it is set on your host (your LLM gateway)
  - `--registry` adds nothing automatically: list your feed's host yourself;
- `CLAUDE_DOCKER_EGRESS_ALLOW`, which takes entries separated by spaces or commas:
  - `host.example.com` matches exactly that host;
  - `.example.com` matches the domain and all of its subdomains;
  - `10.20.0.0/16` (an IPv4 address or CIDR) allows that destination range.

Every entry is validated, and an invalid one aborts startup. Nothing inside a workspace can add to the list: a repo-supplied allowlist would let any repo you open grant itself egress.

Runtime code-fetch needs its hosts listed. Common ones:

- npm: `registry.npmjs.org`
- PyPI / `uvx`: `pypi.org files.pythonhosted.org`
- `tfenv install`: `releases.hashicorp.com`
- Terraform providers: `registry.terraform.io`
- Go: `proxy.golang.org sum.golang.org`

**Always denied**, whatever the list says:

- cloud metadata and link-local addresses (`169.254.0.0/16`, `fe80::/10`, `metadata.google.internal`, `metadata.azure.internal`);
- loopback;
- private ranges (RFC1918, CGNAT, ULA), unless a CIDR entry covers them. These checks run on the address the proxy *resolved*, so an allowlisted name that resolves to an internal address is refused (DNS rebinding);
- any port other than 80 and 443, and `CONNECT` to anything but 443.

A name that is not on the list is refused without being resolved, so a denied request doesn't leak data through DNS either. Private ranges are denied by default because allowing them would re-open rebinding for every allowed name. To reach an internal gateway or registry, add its range as a CIDR entry.

**When something is blocked**, an HTTPS client sees the proxy refuse the `CONNECT` with `403` (curl: `CONNECT tunnel failed, response 403`), and plain HTTP gets squid's access-denied page. At startup, `run.sh` prints the effective allowlist. When the session ends, it prints every host that was blocked, together with the variable to add them to:

```text
claude-docker: egress allowlist blocked: example.org registry.npmjs.org — add them to CLAUDE_DOCKER_EGRESS_ALLOW to permit them
```

`docker logs claude-egress-proxy-<id>` shows the same entries live.

**With `--gh`.** The auth-proxy sidecar joins the internal network too, and squid resolves `github.com` / `api.github.com` / `uploads.github.com` to it. GitHub traffic therefore goes agent → squid → auth proxy (token injected) → GitHub, and the token handling is unchanged.

**Lifecycle.** Startup is fail-closed. If a network can't be created, or the proxy won't start or isn't accepting connections within 15s, `run.sh` aborts before the agent container starts; it never falls back to open egress. Teardown uses the same `EXIT` trap as the gh sidecar.

**Limitations:**

- SSH remotes (port 22) and every other non-HTTP protocol are blocked. Use HTTPS remotes.
- Node's built-in `fetch` ignores proxy env vars, so scripts that use it fail closed. Claude Code, npm, pnpm, pip, uv, curl and Go honour them.
- Telemetry and error-reporting hosts are not on the base list. Claude Code works without them.
- DNS closure relies on Docker ≥ 26, which stopped forwarding external queries from internal networks. Older engines leave a DNS side channel.
- Podman is untested.

## Image vulnerability scanning

CI scans the built image for **known** vulnerabilities with [Trivy](https://trivy.dev), across the whole image filesystem: the Ubuntu base image's system packages, the pinned CLIs, and their transitive dependencies. This is a different question from the one [`update_pins.py`](../update_pins.py) answers — that reports when a *newer* version exists, while a pin can sit on the newest release and still carry a disclosed CVE. It is also a different question from the `npm audit signatures` check above, which establishes that a tarball came from npm's keyring, not that the code inside it is free of known vulnerabilities.

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
