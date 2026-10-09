## 1. Image

- [x] 1.1 `Dockerfile`: install `squid` from the Ubuntu archive (no new image, no pin).

## 2. run.sh

- [x] 2.1 Parse `--egress-lock`; exit 1 without `--api`; help text for `--egress-lock` and `XDG_STATE_HOME`.
- [x] 2.2 `validate_opts`: require `ANTHROPIC_BASE_URL`, validate its host, refuse provider hosts — before runtime detection.
- [x] 2.3 `gen_egress_squid_conf`: denies above the endpoint allow, provider deny, then allow all.
- [x] 2.4 `create_egress_networks`: internal agent network and outbound proxy network.
- [x] 2.5 `start_egress_sidecar`: squid from `$IMAGE` as `proxy`, `--cap-drop ALL`; readiness wait; fail-closed aborts; proxy env and `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` for the agent.
- [x] 2.6 `start_gh_sidecar`: join the internal network under the lock; agent `--add-host` and squid `--add-host` point at it.
- [x] 2.7 EXIT trap saves the log and `.meta` first, then removes the egress resources; `prune_stale_gh` covers `claude-egress-*`; end-of-session denied-host summary.

## 3. Tests

- [x] 3.1 `tests/test_egress_policy.py`: endpoint checks, `--egress-lock` without `--api`, plain `--api` unaffected.
- [x] 3.2 `tests/bats/run.bats`: egress networks, sidecar wiring, every fail-closed abort, gh sidecar under the lock, prune, EXIT trap order, saved log, and `main` with `--api`, `--egress-lock` and `--gh --egress-lock`.
- [x] 3.3 `smoke/assert-in-container.sh` `check_egress` and `smoke/egress.sh`, run by `run.sh` against the real engine; plain and `--gh` cells in `ci.yml`.

## 4. Docs

- [x] 4.1 `docs/auth.md` "API egress lock" (with limitations), `docs/security.md`, `docs/maintenance.md`, `docs/usage.md`, `README.md` flag table, `SECURITY.md` scope.

## 5. Validation

- [x] 5.1 `shellcheck` (v0.11.0, `-S warning`), `bats tests/bats` (100 tests) and `python3 -m unittest discover -s tests -p 'test_*.py'` (151 tests) pass.
- [x] 5.2 `openspec validate egress-lock --strict` passes.
- [x] 5.3 CI egress cells green on `cd69231` (run 37757156170): plain and `--gh`, including the proxy-unaware, DNS and teardown checks; `--gh` reached GitHub through squid and the gh sidecar (HTTP 401 for the fake token).

## 6. Windows validation (manual, real host, before archive)

Run on a Windows 11 host with rootless podman (`podman machine`, WSL2 backend), from PowerShell 7 through `claude-docker.ps1`, against an image built from this branch: commit `2516547`, podman 6.0.2 (client and machine), network backend netavark, squid `7.2-2ubuntu2.2`. All sessions used `--ephemeral`, `ANTHROPIC_BASE_URL=https://example.com` and a fake token. The evidence (session `.log` / `.meta` files, `results-*.txt`, transcript) is kept by the tester.

- [x] 6.1 Image builds with `podman build --format docker`; squid version recorded. (verified: squid `7.2-2ubuntu2.2`, the package version affected by CVE-2026-61642)
- [x] 6.2 Startup refusals: `--egress-lock` without `--api`, no `ANTHROPIC_BASE_URL`, a provider endpoint, an invalid hostname. Each exits 1 and leaves no `claude-egress-*` network. (verified: all four exit 1 with the expected message; `podman network ls` lists none)
- [x] 6.3 Plain cell: `assert-in-container.sh` with `EXPECT_EGRESS=1` reports `RESULT: PASS` (UID 1000), including `egress-bypass` and `egress-dns` on podman's network stack. (verified: 22 passed, 0 failed, exit 0. The entrypoint prints `find: '/root/.claude': No such file or directory` under `--ephemeral`; it comes from the unchanged entrypoint, not this change)
- [x] 6.4 Host-side: the saved `.log` has the `CONNECT example.org:443` tunnel and the denies; `.meta` has 8 keys and `endpoint=example.com`; no `claude-egress-*` / `claude-gh-*` container or network remains. (verified: `TCP_TUNNEL/200 … CONNECT example.org:443` plus five `TCP_DENIED/403` lines, `.meta` complete. Nothing from the session remained; an unrelated `claude-gh-proxy-*` from an earlier session, running for 5 hours, was correctly left alone by the prune)
- [x] 6.5 `--gh` cell (fake token): `RESULT: PASS` including `egress-gh`; nothing left behind. (verified: 23 passed, 0 failed; `egress-gh` got HTTP 401 from GitHub through squid and the gh sidecar)
- [x] 6.6 Manual probes: proxy env; metadata by name and plain HTTP to a non-80 port refused; IPv6 and `host.containers.internal` have no route; cache-manager response recorded. (verified: four proxy vars, `no_proxy` loopback only; `metadata.google.internal` and `http://example.com:8080/` → 403; proxy-unaware `example.org` fails DNS (rc 6), IPv6 and `host.containers.internal` fail to connect (rc 7), `getent hosts` rc 2. A refused `CONNECT` reports `http_code` 000, `http_connect` 403. Cache manager not reachable: `/squid-internal-mgr/info` sent directly to squid and through it by its `visible_hostname` both got 403 with squid's error page, not manager output. The by-name request was refused by the port rule, so the protection comes from that rule, not a manager deny (7.1))
- [x] 6.7 Known issues reproduced: `https://Api.Anthropic.com` starts and provider `CONNECT` is allowed; `https://example.com:8443` starts and the gateway `CONNECT` is refused. (verified: with `Api.Anthropic.com`, `CONNECT api.anthropic.com` → 200, so model traffic reaches the provider under the lock (7.2). With `:8443`, the gateway `CONNECT` → 403, and the summary reads `egress proxy blocked: example.com` without the port (7.3, 7.6))

## 7. Review findings (before archive)

- [ ] 7.1 Decide the proxy (design.md Open Question 1). If squid stays, add `http_access deny manager` as hardening: today the manager is only unreachable because the port rule refuses 3128 (6.6).
- [x] 7.2 Lowercase the endpoint host before the provider check; add `https://Api.Anthropic.com` to the refused cases. (`validate_opts` lowercases the validated host, so the squid config and `.meta` get it lowercased too; unit and bats cases added, and both fail without the fix)
- [x] 7.3 Handle the endpoint port (refuse non-443 at startup, or allow it for the endpoint only); fix `test_gateway_passes`. (allowed for the endpoint only: `validate_opts` parses and validates the port, defaulting by scheme, and squid allows the endpoint on that port below the address denies. `test_gateway_passes` was already right under this choice; unit, bats and rule-order tests added. Checked end to end by the `smoke/egress.sh --endpoint-port` CI cell: with `https://github.com:22` as the endpoint, `CONNECT github.com:22` tunnels and `CONNECT example.org:22` gets 403)
- [ ] 7.4 Decide on enforcing the endpoint vs narrowing the claim (Open Question 2), and align the README row, `--help` text and `docs/auth.md` intro.
- [x] 7.5 `--gh` smoke probe uses an endpoint that proves token injection (`/zen` answers without one). Its status check is sound: a refused `CONNECT` reports `http_code` 000 (6.6), so the accepted 401/403 can only come from GitHub. (the probe is now `GET /user` with no `Authorization` header, and it passes only on 401 `"Bad credentials"`: GitHub answers that for the injected fake token and `"Requires authentication"` for an anonymous request. Both messages were checked against api.github.com directly; the check's parsing was run on both answers and on an unreachable host, which reports 000)
- [x] 7.6 End-of-session summary keeps `host:port` for non-443 denies: a refused `CONNECT example.com:8443` is printed as `example.com`, which reads as the gateway being blocked (6.7). (`egress_save_log` keeps the port and drops only `:443` / `:80`; the bats case covers a `CONNECT` on 8443 and a `GET` on `:80`, and fails without the fix)
- [x] 7.7 `smoke/egress.sh` checks for leftovers per session, not every `claude-egress-*` / `claude-gh-*` on the machine: another session's live sidecar fails it (seen in 6.4). (the session id comes from the startup banner, and the cell checks the two containers and three networks with that id by exact name; it fails if the banner has no id. Checked against a stub `docker`: another session's live `claude-gh-proxy-*` passes, this session's leftovers are named)
