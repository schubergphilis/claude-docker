## Why

The requirement behind #75 turned out narrower than "block all egress". Answers from the review of #101:

- Only **model (LLM) traffic** has to stay in the EU, not git, package installs or web fetches.
- Only **Claude Code**, not other tools on the laptop.
- The customer accepts **logs from a network control**, and we want a **PDF report** on top.
- The image may come from anywhere; the rule is about the **running container**.
- It must be trivial for the team. A deny-all allowlist makes every colleague hit blocked hosts and edit YAML, which hurts adoption, and an unused tool proves nothing.

## What Changes

- `--api` keeps the `--internal` network + squid sidecar, so every connection goes through the proxy and its log is complete.
- **BREAKING (unreleased):** drop `CLAUDE_DOCKER_EGRESS_POLICY` and `egress-policy.yaml`. The proxy allows every host on 80/443 except the model providers' own (`*.anthropic.com`, `*.claude.ai`, `*.claude.com`), and always allows the `ANTHROPIC_BASE_URL` host.
- `--api` requires `ANTHROPIC_BASE_URL`, and refuses one that points at a provider host or isn't a valid hostname.
- Drop the private-range deny and the gh sidecar's exemption from it. Metadata, link-local, loopback and the port rules stay.
- `--api` sets `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`.
- The EXIT trap saves the proxy's access log plus a `.meta` file under `$XDG_STATE_HOME/claude-docker/egress/`.
- New `--report[=FILE]` builds an audit PDF from the saved logs with a stdlib-only `egress_report.py`. It exits 1 if a provider request was not refused.

## Impact

- `run.sh`, new `egress_report.py`, `tests/test_egress_policy.py`, `smoke/egress.sh`, `smoke/assert-in-container.sh`, CI comment, README, SECURITY.md.
- Specs: `api-egress-policy` (reworked), `cli-help` (`--api` text, `--report`, env list).
