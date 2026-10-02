## 1. Lock model traffic, not all traffic

- [x] 1.1 `run.sh`: remove the policy parser, `egress_add`, `EGRESS_HOSTS` / `EGRESS_DSTS`
- [x] 1.2 `run.sh`: require `ANTHROPIC_BASE_URL` under `--api`; refuse a provider host or an invalid hostname, before runtime detection
- [x] 1.3 squid config: allow the endpoint, deny provider suffixes, allow the rest; drop the private-range deny and the gh `/32` exemption
- [x] 1.4 forward `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` under `--api`

## 2. Evidence

- [x] 2.1 EXIT trap saves the proxy log and a `.meta` file under `$XDG_STATE_HOME/claude-docker/egress/`
- [x] 2.2 `--report[=FILE]` runs `egress_report.py` (stdlib PDF), exit 1 on FAIL
- [x] 2.3 help text for `--api`, `--report`, `XDG_STATE_HOME`

## 3. Tests and docs

- [x] 3.1 `tests/test_egress_policy.py`: endpoint checks, report PASS / FAIL / no logs
- [x] 3.2 smoke: open non-model host, refused providers, saved log + meta, PASS report
- [x] 3.3 README "API egress lock", `--api` row, threat model; SECURITY.md scope
