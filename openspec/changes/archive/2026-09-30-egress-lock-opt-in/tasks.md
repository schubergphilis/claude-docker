## 1. Own opt-in

- [x] 1.1 `run.sh`: parse `--egress-lock`; exit 1 when given without `--api`
- [x] 1.2 `run.sh`: gate the endpoint checks, networks, squid sidecar, gh-sidecar join, proxy env and saved log on `--egress-lock` instead of `--api`
- [x] 1.3 help text: `--egress-lock` entry; `--api` no longer describes the lock

## 2. Drop the report

- [x] 2.1 `run.sh`: remove `--report[=FILE]` and its exec block; the end-of-session message no longer points at it
- [x] 2.2 delete `egress_report.py`

## 3. Tests and docs

- [x] 3.1 `tests/test_egress_policy.py`: endpoint checks under `--egress-lock`; `--egress-lock` without `--api`; drop the report tests
- [x] 3.2 smoke: `smoke/egress.sh` passes `--egress-lock`, no report step
- [x] 3.3 README "API egress lock", flag table, threat model; SECURITY.md
