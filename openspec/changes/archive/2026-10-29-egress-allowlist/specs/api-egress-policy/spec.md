# Spec Delta

## ADDED Requirements

### Requirement: --egress-allowlist needs --egress-lock and a file

`--egress-allowlist` SHALL turn on the allowlist mode of the egress proxy. Without `--egress-lock`, `run.sh` SHALL exit 1 before creating any container resource. With `--egress-lock`, it SHALL exit 1 before creating any container resource when neither `--egress-allowlist=FILE` nor `CLAUDE_DOCKER_EGRESS_ALLOWLIST` names a file.

#### Scenario: Allowlist without the lock

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-allowlist needs --egress-lock`, and no container starts

#### Scenario: No file named

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST` is unset
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-allowlist needs a file`, and no container starts

#### Scenario: File given with a space

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist $HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 and suggests `--egress-allowlist=FILE`

### Requirement: Sessions without --egress-allowlist are unchanged

Without `--egress-allowlist`, `run.sh` SHALL NOT read `CLAUDE_DOCKER_EGRESS_ALLOWLIST`, SHALL generate the same squid config as before this change, and SHALL save the same `.meta` keys and no `.conf` file.

#### Scenario: Same config as before

- **WHEN** `run.sh` generates the squid config for `--api --egress-lock`, `--api --egress-lock` with an endpoint port, and `--api --glab --egress-lock`
- **THEN** each is byte-identical to a fixture generated from the commit before this change

#### Scenario: Env var ignored

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST=/nonexistent`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock ~/repo`
- **THEN** no error mentions the allowlist, and the session's `.meta` has the same keys as before this change

### Requirement: Only the effective allowlist is allowed

Under `--egress-allowlist`, the proxy SHALL refuse every request whose host is not on the effective allowlist: the `ANTHROPIC_BASE_URL` host, `claude-docker-api-proxy` under `--api`, and the allowlist file's entries. A private-range destination SHALL be reachable only through a name on the effective allowlist or an endpoint that is a private IPv4 address.

#### Scenario: Listed and unlisted hosts

- **GIVEN** `$HOME/team.allow` lists `example.com`
- **WHEN** a `--egress-allowlist=$HOME/team.allow` session requests `https://example.com/`, `https://example.org/` and `http://example.org/` through the proxy
- **THEN** the first is allowed and the other two are refused

#### Scenario: Endpoint with an empty file

- **GIVEN** `ANTHROPIC_BASE_URL=https://gw.example.eu:8443` and an empty `$HOME/team.allow`
- **WHEN** a `--api --egress-lock --egress-allowlist=$HOME/team.allow` session sends `CONNECT gw.example.eu:8443` through the proxy
- **THEN** it is allowed

#### Scenario: Sidecar name on another port

- **WHEN** a `--api --egress-lock --egress-allowlist=$HOME/team.allow` session requests `http://claude-docker-api-proxy:9999/`
- **THEN** it is refused

#### Scenario: IP-literal requests

- **WHEN** an `--egress-allowlist` session requests `http://10.0.0.5/`, `http://2130706433/` and `http://[2001:db8::1]/`
- **THEN** each is refused

#### Scenario: IPv4 endpoint

- **GIVEN** `ANTHROPIC_BASE_URL=https://10.0.0.5:8443` and an empty `$HOME/team.allow`
- **WHEN** a `--api --egress-lock --egress-allowlist=$HOME/team.allow` session sends `CONNECT 10.0.0.5:8443`, `CONNECT 10.0.0.5:9443` and `CONNECT 10.0.0.6:8443`
- **THEN** the first is allowed and the other two are refused

#### Scenario: Listed on-prem name

- **GIVEN** `$HOME/team.allow` lists `git.corp.example`, which resolves to `10.20.1.2`
- **WHEN** the session requests `https://git.corp.example/`
- **THEN** it is allowed, and the access log shows a connect attempt to `10.20.1.2`

### Requirement: Credential flags add no hosts

Under `--egress-allowlist`, no credential flag SHALL add a host to the effective allowlist.

#### Scenario: --tfe without its host listed

- **GIVEN** an empty `$HOME/team.allow`
- **WHEN** a `--api --tfe --egress-lock --egress-allowlist=$HOME/team.allow` session requests `https://app.terraform.io/`
- **THEN** it is refused

#### Scenario: --gh-direct without GitHub listed

- **GIVEN** an empty `$HOME/team.allow`
- **WHEN** a `--api --gh-direct --egress-lock --egress-allowlist=$HOME/team.allow` session requests `https://github.com/`
- **THEN** it is refused

### Requirement: --gh and --glab need their sidecar's hosts in the file

Under `--egress-allowlist`, when the auth-proxy sidecar runs for `--gh` or `--glab` (a token was found), `run.sh` SHALL exit 1 before creating any container resource, naming the missing hosts, if any of `github.com`, `api.github.com` and `uploads.github.com`, or the proxied GitLab host, is not covered by an entry. An exact entry or a covering `.suffix`, with or without a port, SHALL count.

#### Scenario: GitLab host missing

- **GIVEN** `GITLAB_TOKEN=t`, `GITLAB_HOST=gitlab.corp.example` and an empty `$HOME/team.allow`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --glab --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `gitlab.corp.example`, and no container starts

#### Scenario: Entries that don't cover GitHub

- **GIVEN** `GH_TOKEN=t` and `$HOME/team.allow` listing `.github.io`, `notgithub.com` and `uploads.github.com`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `github.com` and `api.github.com` only

#### Scenario: One GitHub host missing

- **GIVEN** `GH_TOKEN=t` and `$HOME/team.allow` listing `github.com` and `api.github.com`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `uploads.github.com` only

#### Scenario: GitHub covered by a suffix

- **GIVEN** `GH_TOKEN` holds a valid token and `$HOME/team.allow` lists `.github.com`
- **WHEN** an `--api --gh --egress-lock --egress-allowlist=$HOME/team.allow` session clones a repository over HTTPS
- **THEN** the clone succeeds through the sidecar

#### Scenario: GitLab host on its own port

- **GIVEN** `GITLAB_TOKEN=t`, `GITLAB_HOST=gitlab.corp.example:8443` and `$HOME/team.allow` listing `.corp.example`
- **WHEN** a `--api --glab --egress-lock --egress-allowlist=$HOME/team.allow` session requests `https://gitlab.corp.example:8443/`
- **THEN** it is allowed, and `https://gitlab.corp.example:9443/` is refused

### Requirement: Sidecar upstream overrides are refused

Under `--egress-allowlist`, `run.sh` SHALL exit 1 before creating any container resource when `CLAUDE_DOCKER_GH_UPSTREAM` or `CLAUDE_DOCKER_GLAB_UPSTREAM` is set.

#### Scenario: GitHub upstream override

- **GIVEN** `CLAUDE_DOCKER_GH_UPSTREAM=https://other.example` and `$HOME/team.allow` listing the GitHub hosts
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `CLAUDE_DOCKER_GH_UPSTREAM`

### Requirement: Sidecar policy snippets lie outside every workspace

Under `--egress-allowlist`, the files named by `CLAUDE_DOCKER_GH_POLICY` and `CLAUDE_DOCKER_GLAB_POLICY` SHALL pass the same resolve, containment and control-byte checks as the allowlist file, or `run.sh` SHALL exit 1 before creating any container resource. The bytes read for the check SHALL be the bytes staged for the sidecar.

#### Scenario: Policy snippet inside the workspace

- **GIVEN** `CLAUDE_DOCKER_GH_POLICY=$HOME/repo/gh.caddy` and `$HOME/team.allow` listing the GitHub hosts
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --gh --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming `CLAUDE_DOCKER_GH_POLICY` and the workspace

### Requirement: Allowlist rule order

Under `--egress-allowlist`, the proxy's rules SHALL be in this order: the cache-manager deny; the metadata-name deny; a deny of every name not on the effective allowlist; the metadata, link-local and loopback address denies; the provider-host deny; the allows for the endpoint, sidecar and entry ports; the port denies; the allow of the effective allowlist's names; and a final deny of everything.

#### Scenario: Without a sidecar

- **WHEN** `run.sh` generates the squid config for `--api-direct --egress-lock --egress-allowlist=$HOME/team.allow`
- **THEN** its `http_access` lines contain the endpoint allow, no `claude-docker-api-proxy` rule, and end in `deny all`

#### Scenario: Provider host in another spelling

- **WHEN** an `--egress-allowlist` session requests `https://API.Anthropic.com/` and `https://api.anthropic.com./`
- **THEN** both are refused

#### Scenario: Listed name resolving to metadata

- **GIVEN** `$HOME/team.allow` lists a name that resolves to `169.254.169.254`
- **WHEN** the session requests that name
- **THEN** it is refused

#### Scenario: Loopback with a port

- **GIVEN** `$HOME/team.allow` lists `localhost:8080`
- **WHEN** the session requests `http://localhost:8080/`
- **THEN** it is refused

### Requirement: Names off the effective allowlist are not resolved

Under `--egress-allowlist`, the proxy SHALL send no DNS query, forward or reverse, for a request whose host is not a name on the effective allowlist, on any port.

#### Scenario: Secret in an unlisted name

- **WHEN** an `--egress-allowlist` session requests `https://secret.attacker.example/`, `http://SECRET.attacker.example/`, `http://secret.attacker.example:8080/`, `CONNECT secret.attacker.example:8443`, `https://1.2.3.4.secret.attacker.example/`, `http://10.0.0.5/` and `http://[2001:db8::1]/`
- **THEN** each is refused, and the proxy's resolver receives no query for any of them

### Requirement: Allowlist ports

Under `--egress-allowlist`, every name on the effective allowlist SHALL be reachable on 80 and 443, with `CONNECT` only to 443, plus: the endpoint host on the endpoint's port, `claude-docker-api-proxy` on 8080, the `--glab` host on its own port, and, for an entry written with `:port`, that port for the names the entry covers. No other port SHALL be reachable.

#### Scenario: Listed host on its own port

- **GIVEN** `$HOME/team.allow` lists `git.corp.example:8443`
- **WHEN** the session requests `https://git.corp.example:8443/`, `https://git.corp.example/`, `https://git.corp.example:9443/` and `https://example.com:8443/`
- **THEN** the first two are allowed and the last two are refused

#### Scenario: Suffix with a port

- **GIVEN** `$HOME/team.allow` lists `.corp.example:8443`
- **WHEN** the session requests `https://git.corp.example:8443/` and `https://git.corp.example:9443/`
- **THEN** the first is allowed and the second is refused

### Requirement: Allowlist file selection

The allowlist file SHALL be `FILE` from `--egress-allowlist=FILE`, else the path in `CLAUDE_DOCKER_EGRESS_ALLOWLIST`. A leading `~/` in either SHALL be expanded to `$HOME/`. No other file SHALL be read.

#### Scenario: File from the env var

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST=$HOME/team.allow`, listing `pypi.org`
- **WHEN** `run.sh` generates the squid config for `--api --egress-lock --egress-allowlist`
- **THEN** `egress_allowed_names` contains `pypi.org`

#### Scenario: Flag file wins

- **GIVEN** `CLAUDE_DOCKER_EGRESS_ALLOWLIST` names a file listing `pypi.org`, and `$HOME/other.allow` lists `example.com`
- **WHEN** `run.sh` generates the squid config for `--egress-allowlist=$HOME/other.allow`
- **THEN** `egress_allowed_names` contains `example.com` and not `pypi.org`

#### Scenario: Tilde in the flag value

- **WHEN** the user passes `--egress-allowlist=~/team.allow` with the `~` unexpanded by the shell
- **THEN** `run.sh` reads `$HOME/team.allow`

#### Scenario: No fixed fallback file

- **GIVEN** `$XDG_CONFIG_HOME/claude-docker/egress-allowlist` exists and `CLAUDE_DOCKER_EGRESS_ALLOWLIST` is unset
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist ~/repo`
- **THEN** `run.sh` exits 1 with `--egress-allowlist needs a file`

### Requirement: The allowlist file is a readable text file

`run.sh` SHALL exit 1 before creating any container resource, naming the path and its source, when the allowlist file is not a readable regular file, has a symlink chain longer than 40 links, or contains NUL or control bytes other than CR, LF and TAB.

#### Scenario: Missing file

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=/nonexistent ~/repo`
- **THEN** `run.sh` exits 1 with `not a readable regular file` and `/nonexistent`

#### Scenario: Directory as file

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME ~/repo`
- **THEN** `run.sh` exits 1 with `not a readable regular file`

#### Scenario: Control bytes

- **GIVEN** `$HOME/team.allow` contains a NUL byte, or the byte 0x1f
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming the file

### Requirement: The allowlist file is read once and hashed

`run.sh` SHALL read the allowlist file once, and hash and parse the same bytes, including a last line without a newline. It SHALL hash with `sha256sum`, else `shasum -a 256`, and SHALL exit 1 before creating any container resource when neither is available.

#### Scenario: Hash matches the file

- **GIVEN** a `$HOME/team.allow` with CRLF line endings whose last line, `pypi.org`, has no newline
- **WHEN** an `--egress-allowlist=$HOME/team.allow` session starts
- **THEN** its `.meta` has `allowlist_sha256=` equal to `sha256sum` of the file, and `pypi.org` is on the effective allowlist

#### Scenario: No hash tool

- **GIVEN** neither `sha256sum` nor `shasum` is on `PATH`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming the missing tool

#### Scenario: Only shasum

- **GIVEN** only `shasum` is on `PATH`
- **WHEN** an `--egress-allowlist=$HOME/team.allow` session starts
- **THEN** `allowlist_sha256` equals `sha256sum` of the file

### Requirement: The allowlist file lies outside every workspace

`run.sh` SHALL resolve the allowlist file's own symlinks and its directory's, resolve each workspace the same way, and exit 1 before creating any container resource, naming the workspace, when the file lies inside any workspace the session mounts, read-only or not, compared on a `/` boundary.

#### Scenario: File inside the workspace

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/repo/allow ~/repo`
- **THEN** `run.sh` exits 1 naming `~/repo`

#### Scenario: Symlinked workspace

- **GIVEN** `~/work` is a symlink to `/data/work`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=/data/work/allow ~/work`
- **THEN** `run.sh` exits 1 naming the workspace

#### Scenario: Symlink into the workspace

- **GIVEN** `$HOME/team.allow` is a symlink to `$HOME/repo/allow`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1 naming the workspace

#### Scenario: Read-only second workspace

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/docs/allow ~/repo --ro ~/docs`
- **THEN** `run.sh` exits 1 naming `~/docs`

#### Scenario: Sibling directory

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/repo2/allow ~/repo`
- **THEN** the file is accepted

### Requirement: Allowlist entry grammar

Every allowlist entry SHALL be a hostname or a `.suffix` of at least two labels, either with an optional `:port` from 1 to 65535. A host SHALL use only letters, digits, `-` and `.`, be at most 253 characters, have labels of 1-63 characters that neither start nor end with `-`, and have no trailing dot. Entries SHALL be lowercased before they are checked. Blank lines, whole-line and trailing `#` comments, leading and trailing spaces and tabs, and a trailing CR SHALL be ignored.

#### Scenario: Every entry form

- **GIVEN** `$HOME/team.allow` with the lines `# team list`, `PyPI.org  # index`, `.corp.example`, `git.example.com:8443` and `.internal.example:8443`
- **WHEN** `run.sh` generates the squid config for `--egress-allowlist=$HOME/team.allow`
- **THEN** `egress_allowed_names` contains `pypi.org`, `.corp.example`, `git.example.com` and `.internal.example`, and port ACLs exist for `git.example.com` and `.internal.example` on 8443

#### Scenario: Overlapping entries

- **GIVEN** `$HOME/team.allow` lists `api.example.com`, `.example.com`, `pypi.org` and `pypi.org`
- **WHEN** `run.sh` generates the squid config
- **THEN** `egress_allowed_names` contains `.example.com` and `pypi.org` once each and not `api.example.com`, and the proxy image's `squid -k parse` reports no warning

#### Scenario: Comment without a space

- **GIVEN** `$HOME/team.allow` with the lines `pypi.org#index` and `example.org<TAB>#c`
- **WHEN** `run.sh` generates the squid config
- **THEN** `egress_allowed_names` contains `pypi.org` and `example.org`

#### Scenario: Boundary values

- **GIVEN** `$HOME/team.allow` lists a 253-character host made of labels of 63, 63, 63 and 61 characters, `a.example:1` and `b.example:65535`
- **WHEN** the user starts an `--egress-allowlist=$HOME/team.allow` session
- **THEN** the entries are accepted

### Requirement: An invalid allowlist entry is fatal

An entry outside the grammar, a host whose last label is all digits or `0x` plus hex digits, or an entry equal to or under `anthropic.com`, `claude.ai` or `claude.com` in any case SHALL make `run.sh` exit 1 before creating any container resource. `run.sh` SHALL name the file and line of every invalid entry.

#### Scenario: Wildcard spelling

- **GIVEN** line 3 of `$HOME/team.allow` is `*.example.com`
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** `run.sh` exits 1, stderr names the file with `:3`, and suggests `.example.com`

#### Scenario: Several invalid lines

- **GIVEN** lines 2 and 5 of `$HOME/team.allow` are invalid
- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo`
- **THEN** stderr names both `:2` and `:5`

#### Scenario: Invalid hosts and ports

- **WHEN** the user runs `ANTHROPIC_BASE_URL=https://gw.example.eu ANTHROPIC_AUTH_TOKEN=t claude-docker --api --egress-lock --egress-allowlist=$HOME/team.allow ~/repo` with a file whose only line is, in turn, `-a.example.com`, `a-.example.com`, `a..example.com`, `a_b.example.com`, `example.com.`, a 254-character name, a name with a 64-character label, `.com`, `example.com:`, `example.com:0`, `example.com:65536`, `example.com:http`, `https://example.com`, `example.com/x`, `example.com all`, `example.com<TAB>all` and `example.com<CR>x`
- **THEN** `run.sh` exits 1 each time, naming the file and line, and no rejected text reaches the generated config

#### Scenario: Addresses

- **WHEN** the user runs the same command with a file whose only line is, in turn, `10.0.0.5`, `167772165`, `10.5`, `0x7f000001` and `0X7F000001`
- **THEN** `run.sh` exits 1 each time, saying IP entries are not supported

#### Scenario: Provider hosts in any spelling

- **WHEN** the user runs the same command with a file whose only line is, in turn, `api.anthropic.com`, `API.Anthropic.com`, `.ANTHROPIC.com`, `.anthropic.com:8443`, `claude.ai`, `x.claude.ai` and `claude.com`
- **THEN** `run.sh` exits 1 each time, saying the lock refuses model providers' hosts

#### Scenario: Provider names as labels elsewhere

- **WHEN** the user runs the same command with a file listing `notanthropic.com` and `anthropic.com.corp.example`
- **THEN** both entries are accepted and the run reaches runtime detection

### Requirement: DNS is closed under --egress-allowlist

Under `--egress-allowlist`, before any sidecar starts, `run.sh` SHALL check with probe containers that an external name resolves from the session's outbound network, and that the internal network's resolver answers it without an address, each within a time limit. Any other outcome SHALL abort the session, naming DNS. The two probes SHALL have distinct per-session names, be removed by the EXIT trap and be covered by the startup prune.

#### Scenario: Engine forwards DNS

- **GIVEN** an engine whose internal networks resolve external names
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** `run.sh` aborts before the proxy starts, naming DNS as the reason

#### Scenario: DNS unavailable

- **GIVEN** the control lookup from the outbound network fails
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** `run.sh` aborts, saying the DNS check is inconclusive

#### Scenario: Probe times out or can't run

- **GIVEN** the internal probe's resolver times out, refuses the connection, or the probe can't run
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** `run.sh` aborts before the proxy starts

#### Scenario: DNS closed

- **GIVEN** an engine whose internal networks don't resolve external names
- **WHEN** the user starts an `--egress-allowlist` session
- **THEN** both probes pass and the session starts

### Requirement: Allowlist evidence is saved

Under `--egress-allowlist`, `run.sh` SHALL write the generated squid config to `<start>-<id>.conf` in the evidence directory, owner-only, before the agent container starts, and SHALL exit 1 before the proxy starts, naming the path, when the directory or the file can't be created or written. The session's `.meta` SHALL also have `allowlist_file` (the resolved path), `allowlist_sha256` and `allowlist_add_hosts` (the `--add-host` entries given to the proxy).

#### Scenario: Evidence of the list

- **GIVEN** `$HOME/team.allow` is a symlink to `/etc/team/allow`, and `CLAUDE_DOCKER_ADD_HOSTS=git.corp.example:10.0.0.5`
- **WHEN** an `--egress-allowlist=$HOME/team.allow` session exits
- **THEN** the `.meta` has `allowlist_file=/etc/team/allow`, its SHA-256 and `allowlist_add_hosts=` containing `git.corp.example:10.0.0.5`
- **AND** the `.conf` next to it, mode 600, is the config the proxy ran with

#### Scenario: Evidence directory can't be created

- **GIVEN** `XDG_STATE_HOME` points at a path under a regular file
- **WHEN** the user starts an `--egress-allowlist=$HOME/team.allow` session
- **THEN** `run.sh` exits 1 naming the evidence path, and the proxy never starts

#### Scenario: Evidence survives a failed log copy

- **GIVEN** an `--egress-allowlist` session whose engine can't return the proxy's log
- **WHEN** the session exits
- **THEN** the `.conf` file is still present

## MODIFIED Requirements

### Requirement: Model traffic reaches only the configured endpoint

Under `--egress-lock`, `run.sh` SHALL exit 1 before creating any container resource when `ANTHROPIC_BASE_URL` is unset or empty, when its host is not a hostname or IPv4 address of at most 253 characters made of letters, digits, `-` and `.`, when its port is not a number from 1 to 65535, or when its host, compared case-insensitively, is `anthropic.com`, `claude.ai` or `claude.com` or a subdomain of one. The endpoint's port is the one in `ANTHROPIC_BASE_URL`, or the scheme's default (80 for `http`, 443 otherwise). Without `--egress-allowlist`, the proxy SHALL allow the `ANTHROPIC_BASE_URL` host on the endpoint's port, and on 80/443, then deny `.anthropic.com`, `.claude.ai` and `.claude.com`, then allow every other destination that the metadata, loopback and port rules permit. HTTPS SHALL be proxied by `CONNECT` without TLS interception.

#### Scenario: No endpoint

- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo` with a token but no `ANTHROPIC_BASE_URL`
- **THEN** `run.sh` exits 1 with `--egress-lock needs ANTHROPIC_BASE_URL`, and no container starts

#### Scenario: Endpoint is a provider host

- **GIVEN** `ANTHROPIC_BASE_URL=https://api.anthropic.com`
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

#### Scenario: Endpoint is a provider host in another case

- **GIVEN** `ANTHROPIC_BASE_URL=https://Api.Anthropic.com`
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1, and no container starts

#### Scenario: Endpoint on a non-default port

- **GIVEN** an `--egress-lock` session with `ANTHROPIC_BASE_URL=https://gw.example.eu:8443`
- **WHEN** the agent requests `https://gw.example.eu:8443/` and `https://example.org:8443/` through the proxy
- **THEN** the proxy allows the `CONNECT gw.example.eu:8443` and answers `CONNECT example.org:8443` with 403

#### Scenario: Invalid endpoint port

- **GIVEN** `ANTHROPIC_BASE_URL=https://gw.example.eu:65536`
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 with `is not a port number`

#### Scenario: Endpoint smuggles squid config

- **GIVEN** an `ANTHROPIC_BASE_URL` whose host contains a newline or a space
- **WHEN** the user runs `claude-docker --api --egress-lock ~/repo`
- **THEN** `run.sh` exits 1 with `is not a valid hostname`

#### Scenario: Provider host refused, other hosts open

- **GIVEN** an `--egress-lock` session with `ANTHROPIC_BASE_URL=https://example.com`
- **WHEN** the agent requests `https://example.com/`, `https://example.org/` and `https://api.anthropic.com/` through the proxy
- **THEN** the first two succeed and the proxy answers `CONNECT api.anthropic.com` with 403

### Requirement: Metadata and loopback destinations are denied by resolved address

The proxy SHALL deny destinations in `169.254.0.0/16`, `fe80::/10`, `127.0.0.0/8`, `0.0.0.0/8` and `::1`, the metadata addresses `100.100.100.200` (Alibaba Cloud) and `fd00:ec2::254` (AWS IPv6), and the hostnames `metadata.google.internal` and `metadata.azure.internal`, above every allow rule. These checks SHALL apply to the address the proxy resolves for a hostname, not just to IP-literal requests. Without `--egress-allowlist`, private ranges SHALL be reachable. The proxy SHALL permit only ports 80 and 443, and `CONNECT` only to 443, except the endpoint's port for the `ANTHROPIC_BASE_URL` host and the ports the allowlist ports requirement adds; those exceptions SHALL come after the metadata, link-local and loopback denies.

#### Scenario: Cloud metadata

- **WHEN** `curl http://169.254.169.254/` runs in the agent container
- **THEN** the proxy answers 403

#### Scenario: Other clouds' metadata addresses

- **WHEN** a request for `http://100.100.100.200/` or `http://[fd00:ec2::254]/` is sent through the proxy
- **THEN** the proxy answers 403

#### Scenario: Name resolving to loopback

- **WHEN** a request for `http://localhost/` is sent through the proxy
- **THEN** the proxy answers 403

#### Scenario: Non-443 CONNECT

- **GIVEN** `ANTHROPIC_BASE_URL=https://example.com`
- **WHEN** a request for `https://example.com:8443/` is sent through the proxy
- **THEN** the proxy answers 403
