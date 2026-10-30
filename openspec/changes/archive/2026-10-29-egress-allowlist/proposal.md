## Why

`--egress-lock` (#75, #101) keeps Claude Code's model traffic on the `ANTHROPIC_BASE_URL` endpoint and logs every connection, but every other host on 80/443 stays reachable, and the egress-lock change lists "a host or repo allowlist, in any form" as a non-goal. `docs/security.md` accordingly says that if a session is compromised, assume exfiltration already happened, with or without `--egress-lock`.

The teams that use `--egress-lock` mostly have a stricter requirement: all traffic goes to the LLM proxy and to known on-prem hosts, and nothing else (#167). This change reverses the non-goal for a second opt-in only, and keeps the first version to the core: deny everything except the endpoint and the hosts in one allowlist file.

## What Changes

- New wrapper flag **`--egress-allowlist[=FILE]`**, which requires `--egress-lock`. Without a value, `CLAUDE_DOCKER_EGRESS_ALLOWLIST` names the file; with neither, the session refuses to start.
- **The file is the only source.** Under the flag the proxy denies everything except the model endpoint (and the auth-proxy names that only forward there or that the user listed) and the file's entries. Credential flags add nothing.
- Entries are a host or a `.suffix`, with an optional `:port`, and are strictly validated.
- The file must lie outside every workspace, and is read once and hashed.
- Names off the effective allowlist are never resolved, and a probe checks that the engine doesn't forward DNS from the internal network.
- The generated `squid.conf` and the file's path and hash are saved as evidence.
- Sessions without the flag are unchanged.

## Capabilities

### New Capabilities

None. The allowlist is a mode of the existing egress proxy.

### Modified Capabilities

- `api-egress-policy`: the `--egress-allowlist` mode. The two modified requirements change nothing for sessions without the flag.
- `cli-help`: documents `--egress-allowlist` and `CLAUDE_DOCKER_EGRESS_ALLOWLIST`.

## Non-goals

- Changing `--egress-lock`, `--api` or any session without the flag.
- Other ways to add hosts: flags, implied hosts, presets, IP and CIDR entries, a fixed fallback path, a per-repository file. Follow-ups are in design D9.
- Subscription (OAuth) sessions, a data-loss control, TLS interception, per-path rules, non-HTTP protocols.

## Impact

- `run.sh`: flag parsing, file reading and entry validation, the `--gh` / `--glab` checks, squid config generation, DNS probes, evidence, help text and design comments.
- Tests: `tests/test_egress_policy.py`, `tests/bats/run.bats`, `tests/bats/egress.bats`, a squid harness in `tests/egress-proxy/`, `tests/smoke/egress.sh`, `.github/workflows/ci.yml`.
- Docs: `docs/auth.md`, `docs/security.md`, `docs/usage.md`, `docs/vision-and-scope.md`.
