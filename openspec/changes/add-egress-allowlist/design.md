# Design — egress allowlist

## Context

Issue #75 asks for default-deny egress. A firewall inside the container is off
the table because it needs `NET_ADMIN`. The `--gh` auth-proxy sidecar already
gives a template for per-session sidecars. It covers:

- trap-before-create teardown;
- stopped-only prune;
- `run -d` without `--rm`, so a crash can be diagnosed;
- fail-closed startup with exited-sidecar detection;
- host-generated config, staged and mounted `:ro`.

This change reuses all of it. It is not a new subsystem.

## Goals / Non-goals

**Goals:** Under the flag, it is impossible to reach a host that is not on the
allowlist, with any client. Fail closed at every step. Show the user what was
denied. Keep `CapBnd=0xc5` unchanged.

**Non-goals:**
- MITM or content inspection.
- Per-path policy.
- SSH or other non-HTTP egress.
- Podman support in this iteration.
- Bandwidth or rate limits.
- Making the flag the default.
- Closing exfiltration through an allowlisted host. For example, an attacker
  can use their own API key against `api.anthropic.com`, or push to their own
  GitHub repo under an allowlisted `github.com`. Hostname allowlisting cannot
  close that without MITM. The threat model says so.

## Decisions

### D1. Opt-in, not default

The flag is `--egress-allowlist`. The sticky form is
`CLAUDE_DOCKER_EGRESS=allowlist` (same "env var is the knob, shell rc makes it
sticky" pattern as `CLAUDE_DOCKER_TMUX`). Any other non-empty value of
`CLAUDE_DOCKER_EGRESS` is an error, so a typo cannot silently mean "open".

Why not the default: turning it on breaks `git+ssh`, `npm install` and every
runtime fetch until each project writes an allowlist. Shipping that as the
default would push users to turn the feature off rather than configure it. The
issue does not argue for a default either. Revisit once the allowlist file
format has settled in real use.

### D2. The network enforces; the proxy supplies the list

The agent attaches only to `claude-egress-<id>`, created with `--internal`. It
has no gateway and no NAT, so a raw socket goes nowhere. The proxy env vars are
a convenience for clients that honour them, not the boundary. The smoke cell
asserts this with `curl --noproxy '*'` against an allowlisted host: even an
allowed host must be unreachable without the proxy.

The sidecar sits on `claude-egress-out-<id>`, a session-private plain bridge,
and is then `network connect`ed to the internal network. It gets its own bridge
rather than the default `bridge`, so no unrelated container can use it as a
proxy. `network connect` is used instead of repeated `--network` flags because
repeated flags on `run` need Docker ≥ 25.

### D3. Proxy: squid, installed in the agent image

Squid has what the design needs:
- `dstdomain` with a leading-dot suffix;
- `dst` IP ACLs, evaluated on the resolved address, which is what the rebinding
  defence needs;
- ordered `http_access`;
- `CONNECT` support.

tinyproxy was rejected: it filters hostnames with regexes and has no
resolved-address ACL. Caddy (the `--gh` image) was rejected too: stock Caddy
has no forward proxy, and a reverse-proxy generalisation would mean MITMing
every allowlisted host.

The squid **binary** is installed via apt in the existing agent image. The
sidecar runs `"$IMAGE"` with `--entrypoint squid`. No new image is introduced,
for these reasons:
- **Supply chain.** The agent image is already digest-pinned at its base,
  rebuilt through reviewed PRs, and gated by the Trivy scan in CI. `ubuntu/squid`
  would be a second image outside all of that.
- **Version stability.** Squid is an Ubuntu `main` package, so its version
  floats only with security updates within the pinned base's release. A major
  version change can only arrive with a reviewed base-image bump. That matches
  the reason the Caddy pin is hand-managed (`README.md` § Updating pinned tool
  versions): proxy semantics must not change under an automated bump. Nothing
  is added to `pins/` or `update_pins.py`, because there is no new artifact to
  pin.
- **Cost.** A few MB of image size. The agent could run squid itself, but that
  grants nothing, because the agent has no route out.

An image built before this change lacks squid. There, the sidecar exits at
startup and `run.sh` aborts with "rebuild the image". It fails closed.

Sidecar hardening:
- `--user proxy` (squid never starts as root, so it needs no SETUID or SETGID);
- `--cap-drop ALL` and `no-new-privileges`;
- listens on 3128, which is unprivileged;
- no published ports;
- config dir mounted `:ro`;
- no cache (`cache deny all`, no `cache_dir`);
- `via off`, `forwarded_for delete`;
- logs to stdout and stderr, readable with `docker logs`.

### D4. Allowlist sources and trust tiers

The lists are sorted into two squid ACLs. Where a list lands decides which
denies apply to it:

| Tier | Source | Private/IP-literal deny applies? |
|---|---|---|
| **operator** | `CLAUDE_DOCKER_EGRESS_ALLOW` (comma/space separated, `host` or `host:port`); host part of `ANTHROPIC_BASE_URL` when set | **No** — the host user typed it; internal registries/gateways (`10.x`, `litellm.internal`) must work |
| **allowed** | built-in base set; opt-in hosts; approved project file | **Yes** |

The metadata / link-local deny applies to **both** tiers.

**Base set** (from Claude Code's documented network requirements,
<https://code.claude.com/docs/en/network-config#network-access-requirements>):
`.anthropic.com`, `.claude.ai`, `.claude.com`. These cover `api.anthropic.com`,
`claude.ai`, `platform.claude.com`, `downloads.claude.ai`,
`mcp-proxy.anthropic.com` and `code.claude.com`. The optional hosts in that
table are deliberately **not** in the base set:
- Datadog telemetry intake, which is optional per the docs;
- `storage.googleapis.com` (plugin counts);
- `registry.npmjs.org`, which is runtime code fetch;
- `github.com` and `raw.githubusercontent.com` (plugin marketplaces,
  changelog).

Users who need any of these add them. The set is a small constant in `run.sh`.

**Opt-in hosts.** Each opt-in adds the hosts its credential exists for, and
nothing more:
- `--gh` / `--gh-direct`: `github.com`, `api.github.com`, `uploads.github.com`,
  `codeload.github.com`, `.githubusercontent.com`
- `--glab`: `.gitlab.com` (self-hosted GitLab goes in
  `CLAUDE_DOCKER_EGRESS_ALLOW`)
- `--tfe`: `app.terraform.io`
- `--aws`: `.amazonaws.com`, `.awsapps.com`. These are broad by nature. IMDS
  stays denied by the unconditional deny, which is why that deny sits above
  every allow.
- `--registry`: none automatically. Registry URLs live in config files that
  `run.sh` does not parse, and are usually internal. The user adds the host to
  `CLAUDE_DOCKER_EGRESS_ALLOW`, which is the operator tier, so private
  addresses work.
- `--api` (PR #87, not merged yet): covered today by the `ANTHROPIC_BASE_URL`
  rule, which applies whenever that variable is set on the host. If the
  gateway URL has a non-default port, that port is added to the allowed port
  set. Once #87 lands, gate that rule on `WITH_API`.
- Future opt-ins (`--az`, #90) add their row here.

**Ports.** Only 80 and 443 are allowed, plus any explicit port from the
operator tier. The port ACL is global: an operator port opens that port for
every allowlisted host. This is a known ceiling, and per-host ports can come
later if needed. Allowing `CONNECT` to arbitrary ports would turn `github.com:22`
and friends into tunnels.

### D5. Per-project file is a proposal, approved by content hash

The file is `<first workspace>/.claude-docker/allowed-hosts`: one host per
line, with `#` comments and blank lines allowed. Only the first workspace (the
working directory) is read. Additional workspaces don't add hosts.

The file is attacker-controllable, because it is part of the repo being opened.
So:

1. **Strict validation before anything else.** A line must match
   `[A-Za-z0-9.-]`, with an optional leading `.` for a domain suffix. It must be
   at most 253 characters, have no empty label, and no leading `-` (which squid
   could parse as an option). It must contain at least one letter, so IP
   literals are rejected, and at least one inner dot, so `.com` is rejected.
   Any invalid line aborts the run and names the line number. `*.example.com`
   gets a hint to write `.example.com` instead. This is defence against config
   injection: validated lines go into a data file that a squid `acl ...
   "file"` directive reads, never into squid syntax.
2. **Approval.** The normalised list (sorted, deduplicated, newline-terminated)
   is hashed with SHA-256. The hash is checked against
   `${XDG_CONFIG_HOME:-~/.config}/claude-docker/egress-approved`, which holds one
   hash per line:
   - **Hash present:** the list is used silently. An unchanged list is
     re-approved without asking. Editing only comments does not re-prompt.
   - **Absent, interactive (stdin and stderr are TTYs):** `run.sh` prints the
     hosts and asks `[y/N]`. `y` records the hash and uses the list. Any
     other answer ignores the list for this run.
   - **Absent, non-interactive:** the list is ignored and a warning names the
     file. The session still starts on the base, opt-in and operator tiers.
     Ignoring a proposal is itself fail-closed (it means less egress), so
     aborting would be friction with no security benefit.
3. **The approval store must be out of the agent's reach.** If its path falls
   inside any mounted workspace (for example, running on `$HOME`), `run.sh`
   neither reads nor writes it: the agent could forge approvals there. Approval
   is then per-run and interactive only.

Keying approval by content alone means that approving a list in repo A also
approves the identical list in repo B. That is intended: the grant is the set
of hosts, not the repo.

### D6. Unconditional denies, above every allow (the ordered `http_access`)

1. `deny` the metadata names: `metadata.google.internal`,
   `metadata.azure.internal`, `metadata`.
2. `deny` link-local and metadata addresses, matched on `dst`:
   `169.254.0.0/16`, `fe80::/10`, `fd00:ec2::254`. This covers IMDS on every
   cloud, including requests made by name.
3. `deny !egress_ports`.
4. `allow operator_hosts`, then `allow gh_names gh_sidecar` (only the
   `--gh` sidecar's exact names and address, see D8).
5. `deny` IP-literal targets (`dstdom_regex` for a dotted-quad or any `:`).
6. `deny` targets whose resolved address is private, loopback, CGNAT or
   reserved (all of RFC1918, `127/8`, `100.64/10`, `0/8`, multicast and
   reserved, `::1`, `fc00::/7`). This is the DNS-rebinding defence. It also
   stops the sidecar from reaching the Docker host's bridge gateway or its own
   loopback. `dst` matches if **any** resolved address is in range, which is
   the conservative choice.
7. `allow allowed_hosts`.
8. `deny all`.

All `dstdomain` ACLs use `-n`. Without it, squid matches an IP-literal request
against the reverse-DNS name of that IP. An attacker controls the PTR record of
their own IP and could point it at `api.anthropic.com`.

**RFC1918 policy, made explicit.** Private destinations are denied for the
built-in and project tiers, and allowed only for the operator tier. A repo can
therefore never point the agent at your LAN. You can still name an internal
registry or gateway yourself.

### D7. DNS

The agent has no external DNS. On an `--internal` network, Docker's embedded
resolver (127.0.0.11) still answers for container names, but on engines ≥ 26
it does not forward external names for containers that are only on internal
networks. Squid resolves on the agent's behalf through its own bridge. This
closes DNS tunnelling without extra config. The smoke cell asserts it with
`getent hosts example.com` failing in the agent.

Ceiling: Docker engines older than 26 forward external DNS even from internal
networks. There, DNS remains an exfiltration channel. Other egress stays
closed. This is documented, and upgrading the engine fixes it. We don't add a
`--dns` override: engine ≥ 26 sends loopback upstreams from the host
namespace, so the override would be unreliable.

### D8. Composition with `--gh`

When the gh sidecar is active:
- It is created as today on `claude-gh-<id>`, a plain bridge that is its own
  way to reach GitHub.
- It is additionally `network connect`ed to `claude-egress-<id>`.
- `--add-host` points the three hostnames at its **internal** IP.
- squid's `hosts_file` maps those three hostnames to the same internal IP.
  A narrow rule, `allow gh_names gh_sidecar` (exact names **and** that one
  address), admits them past the private-address deny. Proxy-aware clients
  `CONNECT` through squid and land on the gh sidecar, not on real GitHub, so
  token injection is unchanged.
- `NO_PROXY` was rejected. curl, Go and Python all treat a `NO_PROXY` entry of
  `github.com` as a domain suffix, so `codeload.github.com` and every other
  `*.github.com` host would also bypass squid. On the internal network that
  means they are unreachable. The smoke cell caught this.
- For this to work, the gh sidecar has to exist before squid starts. So
  `run.sh` creates the egress networks first, then runs the gh block, then
  starts squid.

The agent still attaches only to the internal network. This answers #12's open
question for now: one sidecar per role (credential vs egress), joined on a
shared internal network, instead of one multi-role proxy.

The gh sidecar's own egress is limited to its reverse-proxy upstreams, and it
listens only for the three GitHub site blocks. Hosts it does not intercept
(`codeload.github.com`, `*.githubusercontent.com`) go through squid, via the
`--gh` opt-in hosts.

### D9. What "deny" looks like

- **In-session:** a client gets `403` from squid. curl reports "CONNECT tunnel
  failed, response 403". Direct connections get "network unreachable" or a name
  resolution failure. The statusline tag gains `egress`.
- **Startup:** `run.sh` prints the size of the allowlist and the
  sidecar name, so the user can follow `docker logs`.
- **Exit:** `run.sh` reads the sidecar's access log before teardown and prints
  every denied host once. It then names the two places to allow a host: the
  project file and `CLAUDE_DOCKER_EGRESS_ALLOW`. This is the main defence
  against first-run friction.

We don't use custom squid error pages. `deny_info` with a custom template would
replace squid's shipped error directory, which is a startup failure risk, and
`CONNECT` clients never render the body anyway.

### D10. Lifecycle

This reuses the gh pattern exactly:
- Names come from the stage-dir suffix.
- The EXIT trap is extended **before** anything is created. Order is: gh
  sidecar, egress sidecar, then the three networks. The gh sidecar holds an
  endpoint on the egress network, so it must go first.
- The startup prune also matches `claude-egress-*` and `claude-egress-proxy-*`,
  stopped containers only.
- Failure to create either network, start the sidecar, connect it, see
  `Accepting HTTP Socket connections` in its log within 15 s, or read its
  internal IP aborts the run. If the sidecar exits early, its log tail is
  printed.
- The final agent `run` is no longer the script's last command. Its exit code
  is captured, the deny summary runs, and the script exits with the agent's
  code.

## Risks / Trade-offs

- **The flag not being used** leaves egress open. This is the status quo, and
  the README threat model now says the flag exists.
- **Exfiltration through allowlisted hosts** is not closed (see Non-goals).
- **The proxy image floats with apt security updates** of the pinned base.
  This is accepted in D3.
- **Podman is refused**, so users on podman can't use the feature. That is
  better than an unverified boundary.
- **`git+ssh` breaks.** Documented; use HTTPS remotes (with `--gh` they are
  authenticated anyway).
- **`--registry` needs manual allowlisting** (D4).

## Migration

None. The feature is opt-in, and behaviour without the flag is unchanged.
