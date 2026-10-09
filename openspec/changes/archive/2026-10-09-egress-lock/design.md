## Context

Issue #75, as narrowed in the review of #101: a customer needs proof that the
model traffic of a session (its prompts) goes only to an EU-hosted gateway, not
to the model provider directly. `--api` (#104) already points Claude Code at a
gateway; this change makes that checkable.

claude-docker deliberately had no egress filtering, because maintaining
allowlists costs every user configuration effort. This design keeps that
property. The lock is a separate opt-in, has no allowlist, and leaves sessions
without it unchanged, so the cost lands only on the teams that need the
evidence.

Constraints:

- No new capabilities in the agent container. `CapBnd` stays `0xc5`, so the
  boundary can't be an in-container firewall.
- The `--gh` auth-proxy sidecar already has a lifecycle to copy: per-session
  networks, trap-before-create teardown, a stopped-only prune, `run -d` without
  `--rm`, exited-sidecar detection, and a host-generated config mounted `:ro`.

## Goals / Non-Goals

**Goals:**

- Model traffic from an `--egress-lock` session cannot reach the providers'
  own hosts.
- Every connection the session makes is recorded on the host, and a client
  that ignores the proxy has no other way out, so the record is complete.
- No configuration beyond `ANTHROPIC_BASE_URL`, which `--api` already needs.
- Sessions without `--egress-lock`, including plain `--api`, are unchanged.

**Non-Goals:**

- Restricting non-model traffic. git, package managers and the web stay open.
  This is not a data-loss control: a compromised session can still send data
  to any non-provider host over HTTPS. The log shows that it did.
- Producing an audit report. That stays with the team that needs one.

## Decisions

### D1. Its own flag, composed with `--api`

`--egress-lock` turns on everything in this change; `--api` alone does not.
Most gateway users don't need a sidecar, an internal network, or a log of every
connection kept on their host. The lock needs `--api` for the endpoint and
token forwarding, so `--egress-lock` without it exits 1.

*Rejected:* `--api` implying the lock (the first draft). It put the sidecar and
an unrotated log on every gateway user.

### D2. The network enforces; the proxy decides and records

The agent container's only network is `claude-egress-<id>`, created with
`--internal`, so it has no gateway. The squid sidecar `claude-egress-proxy-<id>`
starts on a normal per-session network `claude-egress-out-<id>` and is then
connected to the internal one. We use a dedicated outbound network rather than
the engine default for two reasons. Rootless podman's default (pasta) can't be
multi-attached, and a dedicated network keeps other containers away from the
proxy port.

The agent gets `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY`
pointing at the proxy's IP, plus `no_proxy` / `NO_PROXY` set to loopback only. A
client that ignores them has no route and fails, which is what makes the
proxy's log complete. This is load-bearing, and the smoke cell asserts it with
proxy-unaware probes rather than assuming it.

**DNS.** The agent never needs external DNS, because squid resolves names. On
an internal network, Docker's embedded resolver doesn't forward external
queries (moby ≥ 26), which closes DNS as a side channel. The smoke cell asserts
this too. Older engines leave the side channel open (documented).

### D3. Allow the endpoint, refuse the providers, allow the rest

The `http_access` rules, in order:

1. deny `metadata.google.internal`, `metadata.azure.internal` (name);
2. deny `dst 169.254.0.0/16 fe80::/10` (metadata, link-local);
3. deny `dst 127.0.0.0/8 0.0.0.0/8 ::1` (loopback);
4. allow `dstdomain -n <ANTHROPIC_BASE_URL host>` on the endpoint's port;
5. deny ports other than 80/443, and `CONNECT` to anything but 443;
6. allow `dstdomain -n <ANTHROPIC_BASE_URL host>`;
7. deny `dstdomain -n .anthropic.com .claude.ai .claude.com`;
8. allow all.

The address denies in 1–3 come first, so nothing re-opens them. Rule 4 lets
a gateway on another port work (an `https://gw:8443` gateway, LiteLLM's
default `http://litellm:4000`) while every other host stays on 80/443. The
endpoint's port is the one in `ANTHROPIC_BASE_URL`, else the scheme's
default. The `dst` rules
apply to the address squid resolves, so a name that resolves to loopback is
refused too. The endpoint allows come before the provider deny. Startup
already refuses a provider endpoint (D4), so this only matters if that check
is wrong. `-n` stops a PTR record from turning an IP-literal request into an
allowed name. Private ranges are reachable, so an on-prem git server or
registry works.

*Rejected:* a deny-all allowlist in a host-side policy file (the first draft).
It was precise, but every colleague would hit blocked hosts and edit YAML. That
hurts adoption, and a tool the team doesn't use proves nothing. The requirement
only covers model traffic.

### D4. Endpoint checks at startup

Under `--egress-lock`, `run.sh` exits 1 before creating any container resource
if any of these holds:

- `ANTHROPIC_BASE_URL` is unset or empty. Claude Code would then call
  `api.anthropic.com`, which the lock refuses.
- Its host fails the hostname/IPv4 validator, which allows only letters,
  digits, `-` and `.`, at most 253 characters.
- Its port isn't a number from 1 to 65535.
- Its host is a provider host. The host is lowercased after the validator,
  because `dstdomain` is case-insensitive: compared as written,
  `https://Api.Anthropic.com` passed the check, and rule 5 then let provider
  traffic through (found in review, reproduced in tasks.md 6.7).

The validators are also config-injection defence. The host and port are the
only variables written into `squid.conf`, so no whitespace, quote or newline
can reach it.

### D5. squid in its own image, Alpine, built on first use

The proxy is squid, in an image of its own: `FROM alpine:<digest>`, `apk add
'squid>=7.6'`, `USER squid`. `run.sh` writes that Containerfile and builds it
the first time a host runs `--egress-lock`. The tag is the Containerfile's
`cksum`, so a changed recipe builds a new image instead of reusing a stale
one. `CLAUDE_DOCKER_EGRESS_PROXY_IMAGE` replaces it with an image the user
supplies. The sidecar runs as `squid`, with `--cap-drop ALL` and
`no-new-privileges`, listens on 3128 and holds no secret. The config refuses
squid's cache manager first (`http_access deny manager`, CVE-2024-23638's
workaround), rather than relying on the port rules to refuse it.

Review asked for squid out of the agent image (it shipped to every user, with
a setuid `pinger`) and for the two-daemon question to be settled. The options:

| Option | For | Against |
|---|---|---|
| squid in the agent image (first build) | no pull, archive-trusted | in every image; Ubuntu's 7.2 has no CVE-2026-61642 fix, and Ubuntu rates squid CVEs "Medium", below the Trivy gate |
| `ubuntu/squid`, digest-pinned | only lock users carry it | same 7.2 without the fix; `latest` last rebuilt 2025-11 |
| **Alpine + squid, built on first use** (chosen) | squid 7.6 with the fix; only lock users carry it; no registry to run | first lock session builds (needs Docker Hub and Alpine mirrors); a manual base pin |
| Alpine + squid, published to GHCR | no build on users' hosts | a publish workflow, signing and a registry to maintain |
| Caddy + `forwardproxy`, one daemon | one config language | see below |
| HAProxy / tinyproxy | — | no forward `CONNECT` / weaker record |

**Caddy + `forwardproxy` was spiked and rejected.** Built with xcaddy (Caddy
2.11.7, plugin at its last commit) and probed locally:

- The plugin's own `acl`/`ports` can't express the policy. Ports are global
  and checked before the ACL, so "the endpoint on its own port" and
  "`CONNECT` only to 443" need Caddy route matchers around it.
- Its name ACL is case- and trailing-dot-sensitive: under `deny
  *.anthropic.com`, `API.Anthropic.com` and `api.anthropic.com.` both
  tunnelled. The provider deny would have to live in regexps.
- A deny is a bare 403 in the access log, the same as a failed dial, and a
  malformed request leaves no log line at all.
- One daemon doesn't materialise: routing `CONNECT github.com` to its own
  GitHub site through `/etc/hosts` also catches its `reverse_proxy` to the
  real GitHub, so it would still be two containers.
- The plugin calls itself experimental, its last code change was 2025-01,
  and it has no release tags since 2019.

squid expresses the policy natively and was already tested here. Alpine's
squid 7.6 was run against the generated config (endpoint on 443 and on 22):
every allow and deny matched what squid 7.2 does in CI, and the cache manager
was refused.

**CVE tracking.** CI scans the proxy image with the same advisory and gate
Trivy passes as the agent image. The image is built once per host and then
reused, so a user takes up a newer Alpine squid by removing the image (see
`docs/auth.md`). A bump of `EGRESS_PROXY_BASE` or the squid floor changes the
tag and rebuilds everywhere.

### D6. The log is the evidence

When a session whose proxy started exits, the EXIT trap writes the proxy's
access log (squid's default format) to
`$XDG_STATE_HOME/claude-docker/egress/<start>-<id>.log`, and writes a `.meta`
file next to it with the start and end time, user, host, workspaces, image,
image ID and endpoint. This happens before the proxy is removed. The directory
is never mounted into a container. `run.sh` never rotates or deletes saved
logs: they are the evidence, and the flag is opt-in. At session end it prints
the distinct denied hosts and the log path.

*Rejected:* `--report`, a stdlib PDF writer (the second draft). That was
reporting for one audit, and it added a host `python3` dependency.

### D7. Telemetry off under the lock

The agent gets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. Telemetry, error
reporting and the updater talk to hosts the proxy refuses, so they would only
fill the log with denies.

### D8. Composition with `--gh`

The gh sidecar keeps its own outbound network and also joins
`claude-egress-<id>`. The agent's `--add-host` entries for `github.com`,
`api.github.com` and `uploads.github.com` use the sidecar's address on that
network, and the agent isn't attached to `claude-gh-<id>`. squid gets the same
`--add-host` entries. Its `hosts_file` is `/etc/hosts`, so `CONNECT
github.com:443` reaches the gh sidecar, which still terminates TLS and injects
the token. GitHub deliberately doesn't bypass the proxy: `no_proxy=github.com`
also matches `codeload.github.com`, which has no direct route.

### D9. Fail-closed lifecycle

This mirrors `--gh`. Resource names derive from the stage-dir suffix. The EXIT
trap is installed before anything is created. It saves the log first, then
removes the proxy, the gh sidecar, and the networks (the egress ones last,
because the gh sidecar may be attached to the internal one). The stopped-only
prune also covers `claude-egress-proxy-*` and `claude-egress-*`.

Each of these aborts before the agent container starts:

- a network can't be created;
- `run -d` fails, or the proxy can't join the internal network;
- the proxy exits during startup (its last log lines are printed);
- the proxy isn't accepting connections within 15s;
- the proxy's address can't be read.

It never falls back to open egress.

### D10. Managed settings pin Claude Code's endpoint

Claude Code takes `ANTHROPIC_BASE_URL` from a project's `.claude/settings.json`
over the process environment (found in review), so a workspace could move the
model traffic to any host that isn't a provider's. The startup check sees only
the environment. Under the lock, `run.sh` therefore writes Claude Code managed
settings and mounts them read-only at `/etc/claude-code/managed-settings.json`.
Managed settings take precedence over every other source. `/etc/claude-code`
is root's, so the agent can't add a file next to them either.

Pinning the URL alone isn't enough. A project that sets
`CLAUDE_CODE_USE_BEDROCK`, `_VERTEX` or `_FOUNDRY` and that backend's base URL
sends the traffic there, so all three are pinned to `0`. Tested against Claude
Code 2.1.289 with two loopback logging servers: a project override via
`settings.json`, `settings.local.json`, `--settings`, Bedrock, Vertex and
Foundry each reached the managed endpoint and never the override, while
without managed settings the `settings.json` override won.
`tests/managed-settings-precedence.sh` repeats that in CI against the image.

The whole URL goes into JSON, so `validate_opts` accepts only RFC 3986
characters in it and nothing needs escaping.

*Rejected:* narrowing the claim to "not Anthropic directly". The fix is one
file, and the guarantee is what the feature is for.

## Risks / Trade-offs

- **The endpoint pin is Claude Code's** (D10). Other programs in the session
  reach every non-provider host by design, and the proxy can't tell model
  traffic from other traffic without TLS interception. A model backend added
  in a later Claude Code would need pinning off too; the CI precedence test is
  where that shows when the `claude-code` pin moves.
- **Log completeness** depends on squid (a smuggling bug like CVE-2026-61642
  hides requests from the log; D5 requires the fixed 7.6), and on `run.sh`
  reaching its EXIT trap. A SIGKILLed `run.sh` loses that session's log.
- **The first `--egress-lock` session builds the proxy image** (D5), so it
  needs Docker Hub and Alpine's mirrors and takes longer. Hosts without that
  access set `CLAUDE_DOCKER_EGRESS_PROXY_IMAGE`. A built image is reused until
  removed, so a newer Alpine squid needs a manual `image rm` or a pin bump.
- **A `CONNECT` to a provider's raw IP** isn't matched by the name deny.
  Claude Code doesn't do that, and the log would show it.
- **A gateway set only in `settings.docker.json`** is invisible to `run.sh`,
  which refuses to start. Users have to export it.
- **Node's built-in `fetch`** ignores proxy variables and fails closed.
- **Docker < 26** leaves a DNS side channel. **Podman** isn't in CI. It was
  validated manually on Windows 11 with podman 6.0.2 / netavark (tasks.md §6,
  and 7.8 for the proxy image's first-use build and the managed settings):
  the internal network, DNS closure and teardown behave as on Docker.

## Open Questions

1. ~~**Proxy choice.**~~ squid in its own Alpine image: D5.
2. ~~**Enforce the endpoint, or narrow the claim.**~~ Enforced: D10.
