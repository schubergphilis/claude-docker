## Why

Review of #101 (stefanwb, 2026-09-27):

- Most gateway users don't need an egress lock. Under `--api` they'd all get the sidecar, the internal network, and an unrotated log of every connection on their host. The lock needs its own switch that composes with `--api`.
- The saved logs are the evidence. Turning them into a PDF is reporting for one audit: it adds a PDF writer and a host `python3` dependency to claude-docker, so it belongs with the team that needs it.

## What Changes

- New wrapper flag `--egress-lock` turns on the internal network, the squid sidecar, the endpoint checks, `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and the saved log. `--api` alone goes back to #104's behaviour (endpoint env forwarding, token check, CA).
- `--egress-lock` without `--api` is a startup error.
- **BREAKING (unreleased):** drop `--report` and `egress_report.py`. The saved `.log` / `.meta` files are unchanged, so a report can be built outside this repo.

## Impact

- `run.sh`, `egress_report.py` (deleted), `tests/test_egress_policy.py`, `smoke/egress.sh`, CI comment, README, SECURITY.md.
- Specs: `api-egress-policy` (trigger, report removed), `cli-help` (`--egress-lock` instead of `--report`).
