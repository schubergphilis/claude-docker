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

### D5. squid, installed into the agent image (open: see Open Questions)

Caddy, which the `--gh` sidecar uses, can't forward-proxy out of the box. Its
forward proxy is a third-party plugin that isn't in the official image. squid's
`CONNECT` keeps TLS end-to-end. As built, `squid` comes from the Ubuntu
archive into the agent image, and the sidecar runs `$IMAGE` with
`--entrypoint /usr/sbin/squid`, as `proxy`, with `--cap-drop ALL` and
`no-new-privileges`. It listens on 3128 and holds no secret. Why:

- There's no extra pull. The image is already local.
- The bytes come from the archive the base image already trusts, and Trivy
  scans them with the image.
- There's nothing for `pins/` to track. squid moves only within the Ubuntu
  release, and a major upgrade arrives with a `FROM` bump.

The costs were raised in review:

- squid ships in every user's image, though only `--egress-lock` uses it. It
  also adds a setuid-root binary, `/usr/lib/squid/pinger`, to the agent
  container. That's inert under `no-new-privileges`, but it's there for every
  user.
- Running squid and Caddy means two proxy daemons to maintain.
- Ubuntu rates nearly every squid CVE "Medium", so the HIGH/CRITICAL Trivy
  gate doesn't flag them. One example is CVE-2026-61642, request smuggling via
  `Transfer-Encoding`, which is fixed upstream but has no Ubuntu package yet. A
  smuggled request doesn't appear in the access log, which undermines the
  evidence (though not the provider deny).

Alternatives:

| Option | For | Against |
|---|---|---|
| squid in the agent image (as built) | no pull, archive-trusted, no pin | in every image, distro CVE lag, second daemon |
| `ubuntu/squid`, digest-pinned, pulled only under `--egress-lock` (like `PROXY_IMAGE`) | only lock users carry it, pin is reviewed | same daemon and CVE lag, another pin to maintain |
| Caddy + `forwardproxy` plugin, built with `xcaddy` and pinned | one daemon for `--gh` and the lock, one config | we build and maintain a Caddy image; plugin is third-party |
| HAProxy | mature | no forward `CONNECT` |
| tinyproxy | small | weaker security record |

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

## Risks / Trade-offs

- **"Not Anthropic directly", not "only the gateway".** Claude Code takes
  `ANTHROPIC_BASE_URL` from a workspace's `.claude/settings.json` over the
  process environment, and the startup check only sees the environment. A
  project can therefore send model traffic to any non-provider host. The proxy
  can't tell model traffic from other traffic without TLS interception.
  Documented as a limitation; see Open Questions.
- **squid's cache manager** isn't reachable from the agent, but only because
  the port rule refuses 3128 (tasks.md 6.6). There is no explicit
  `http_access deny manager` (CVE-2024-23638's workaround), so a change to
  the port rules would expose it.
- **The end-of-session summary drops the port.** A refused `CONNECT
  gateway:8443` is printed as `gateway`, which reads as the endpoint being
  blocked. The log itself keeps `host:port`.
- **Log completeness** depends on squid (CVE-2026-61642, D5), and on `run.sh`
  reaching its EXIT trap. A SIGKILLed `run.sh` loses that session's log.
- **A `CONNECT` to a provider's raw IP** isn't matched by the name deny.
  Claude Code doesn't do that, and the log would show it.
- **A gateway set only in `settings.docker.json`** is invisible to `run.sh`,
  which refuses to start. Users have to export it.
- **Node's built-in `fetch`** ignores proxy variables and fails closed.
- **Docker < 26** leaves a DNS side channel. **Podman** isn't in CI. It was
  validated manually on Windows 11 with podman 6.0.2 / netavark (tasks.md §6):
  the internal network, DNS closure and teardown behave as on Docker.

## Open Questions

1. **Proxy choice (D5).** Keep squid in the agent image, move it to a
   digest-pinned image pulled only under `--egress-lock`, or replace it with
   Caddy + `forwardproxy` for both sidecars. If squid stays: add `http_access
   deny manager` as hardening, and decide how its CVEs are tracked given the Trivy gate's
   blind spot.
2. **Enforce the endpoint, or narrow the claim.** Either keep "not Anthropic
   directly" and say so everywhere, or stop a project from overriding the
   endpoint. One candidate, untested: put `ANTHROPIC_BASE_URL` in Claude Code's
   managed settings in the container (`/etc/claude-code/managed-settings.json`),
   which take precedence over project settings.
