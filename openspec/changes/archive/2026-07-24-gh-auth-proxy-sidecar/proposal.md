# GitHub Auth Proxy Sidecar

## Why

`--gh` currently forwards the host's GitHub token into the agent container as `GH_TOKEN` — Claude Code can read it trivially (`gh auth token`, `printenv`) and the fallback path forwards the host's *long-lived, broad-scope* gh OAuth token. A compromised or prompt-injected session can exfiltrate a credential that works from anywhere, indefinitely. Keeping the token out of the agent container entirely — in a per-session sidecar proxy that injects auth in transit — removes the exfiltratable secret while keeping `gh` and `git` working unchanged, and adds a policy point where destructive API calls (e.g. repo deletion) can be blocked.

## What Changes

- New per-session sidecar container (pinned Caddy image) that holds the GitHub token, terminates TLS for `github.com` / `api.github.com` / `uploads.github.com` with an ephemeral per-session CA, injects the real `Authorization` header, and forwards to GitHub.
- `--gh` no longer forwards the real token into the agent container. **BREAKING** (behavioral): `gh auth token` / `GH_TOKEN` inside the agent container now yield a placeholder, not the host token. Traffic to GitHub is redirected to the sidecar via `--add-host` entries; the sidecar's ephemeral root CA is installed into the agent container's trust store by the entrypoint.
- Each `run.sh` invocation gets its own Docker network, sidecar, CA, and audit log — concurrent sessions are fully isolated from each other. Teardown extends the existing EXIT trap.
- Token acquisition on the host is unchanged (env `GH_TOKEN`/`GITHUB_TOKEN`, else `gh auth token`, else silent skip) — the token is just handed to the sidecar instead of the agent container.
- Request filtering: the sidecar ships a default policy blocking repository deletion (`DELETE /repos/{owner}/{repo}`) and supports user-supplied policy extensions; every proxied request is logged (method, path, status) retrievable via container logs.
- New `--gh-direct` escape hatch restoring the legacy in-container token forwarding for setups the proxy cannot serve.
- In-container `gh auth login` persistence (`/root/.config/gh` unmask under `--gh`) stays masked while the sidecar is active; the unmask remains only for the no-token fallback and `--gh-direct`.

## Scope and Follow-ups

This change is **deliberately GitHub-only**: it is the proof of concept for the credential-isolation sidecar pattern (per-session network/sidecar lifecycle, ephemeral CA + trust distribution, fail-closed startup, policy point, audit logging). Planned follow-ups, explicitly out of scope here:

- **Terraform Cloud and GitLab** — expected to be near-1:1 ports once this lands: both are bearer-token APIs on a single hostname, so the header-injection sidecar transfers directly (separate future changes).
- **AWS** — requires its own research and design change: AWS uses SigV4 request *signing*, not bearer tokens, so header injection does not transfer. Candidate directions to evaluate there: a re-signing sidecar (e.g. awslabs/aws-sigv4-proxy, dummy-credential placeholder, `AWS_ENDPOINT_URL` redirection instead of DNS interception) versus vending short-lived scoped STS credentials via the ECS container-credentials endpoint. The chassis built here (session lifecycle, teardown, policy/audit pattern) is expected to be reused either way.

## Capabilities

### New Capabilities

- `gh-auth-proxy`: Per-session GitHub auth proxy sidecar — token isolation, ephemeral CA and trust distribution, transparent redirection of GitHub traffic, session isolation and lifecycle, request filtering policy, and audit logging.

### Modified Capabilities

- `external-cli-tools`: The `--gh` requirement changes — the host token SHALL NOT reach the agent container by default; authenticated GitHub access is provided via the sidecar; a placeholder `GH_TOKEN` keeps `gh` operational; `--gh-direct` preserves the legacy forwarding behavior; gh config masking rules updated accordingly.

## Impact

- `run.sh`: sidecar lifecycle (network create, sidecar start, CA extraction wait-loop, `--add-host` wiring, env plumbing, EXIT-trap teardown), new `--gh-direct` flag, generated Caddyfile in the existing stage dir.
- `entrypoint.sh`: install the staged proxy root CA via `update-ca-certificates` before privilege drop.
- `Dockerfile`: none expected (`ca-certificates` already present for the existing CLIs); verify during implementation.
- New pinned sidecar image reference (Caddy, digest-pinned) — pin recorded in `run.sh` with `CLAUDE_DOCKER_PROXY_IMAGE` override; first `--gh` run pulls it.
- `README.md`: credential opt-in table, threat model, new proxy section, manual-checklist additions.
- Verification: new `run.sh`-driven integration harness under `tests/` against a mock GitHub upstream (the existing `smoke/smoke.sh` never invokes `run.sh`, and CI has no GitHub credentials); real-credential assertions live in the README manual checklist.
- Known limitations (documented): TLS clients that don't read the system trust store (e.g. Python `certifi`-bundled) get certificate errors when contacting the proxied GitHub hostnames; SSH remotes remain unsupported (unchanged); self-hosted / custom-hostname GitHub (GitHub Enterprise **Server**, e.g. `github.mycompany.com`, and GHEC data-residency `*.ghe.com`) is out of scope — note github.com organizations, including those under a GitHub Enterprise Cloud account, are fully covered since they use the same `github.com` / `api.github.com` hostnames. Custom-hostname users keep `--gh-direct` (matching today's `--gh`, which never supported custom hostnames either).
