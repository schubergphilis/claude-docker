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

Run on a Windows 11 host with rootless podman (`podman machine`, WSL2 backend), from PowerShell 7 through `claude-docker.ps1`, against an image built from this branch. Record the commit, podman version, network backend and squid version.

- [ ] 6.1 Image builds with `podman build --format docker`; squid version recorded.
- [ ] 6.2 Startup refusals: `--egress-lock` without `--api`, no `ANTHROPIC_BASE_URL`, a provider endpoint, an invalid hostname. Each exits 1 and leaves no `claude-egress-*` network.
- [ ] 6.3 Plain cell: `assert-in-container.sh` with `EXPECT_EGRESS=1` reports `RESULT: PASS` (UID 1000), including `egress-bypass` and `egress-dns` on podman's network stack.
- [ ] 6.4 Host-side: the saved `.log` has the `CONNECT example.org:443` tunnel and the denies; `.meta` has 8 keys and `endpoint=example.com`; no `claude-egress-*` / `claude-gh-*` container or network remains.
- [ ] 6.5 `--gh` cell (fake token): `RESULT: PASS` including `egress-gh`; nothing left behind.
- [ ] 6.6 Manual probes: proxy env; metadata by name and plain HTTP to a non-80 port refused; IPv6 and `host.containers.internal` have no route; cache-manager response recorded.
- [ ] 6.7 Known issues reproduced: `https://Api.Anthropic.com` starts and provider `CONNECT` is allowed; `https://example.com:8443` starts and the gateway `CONNECT` is refused.

## 7. Review findings (before archive)

- [ ] 7.1 Decide the proxy (design.md Open Question 1); if squid stays, add `http_access deny manager`.
- [ ] 7.2 Lowercase the endpoint host before the provider check; add `https://Api.Anthropic.com` to the refused cases.
- [ ] 7.3 Handle the endpoint port (refuse non-443 at startup, or allow it for the endpoint only); fix `test_gateway_passes`.
- [ ] 7.4 Decide on enforcing the endpoint vs narrowing the claim (Open Question 2), and align the README row, `--help` text and `docs/auth.md` intro.
- [ ] 7.5 `--gh` smoke probe asserts `http_connect` = 200 and uses an endpoint that proves token injection.
