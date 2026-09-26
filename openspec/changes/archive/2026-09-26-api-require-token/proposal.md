## Why

Review of #104 (stefanwb, tested on Claude Code 2.1.282): with a claude.ai OAuth
login in the volume and only `ANTHROPIC_BASE_URL` set, Claude Code sends the
**OAuth token** to the gateway as `Authorization: Bearer`. With
`ANTHROPIC_AUTH_TOKEN` or `ANTHROPIC_API_KEY` set it sends only that. So
`--api` without a gateway token leaks the user's Anthropic credential to a
third-party endpoint. An empty value (a failed `$(helper)` or `op read`) is the
same case.

Separately, `CLAUDE_DOCKER_API_CA` goes into the system trust store, which widens
trust to every TLS connection in the container, and the docs did not say so.

## What Changes

- `run.sh` fails closed under `--api` unless `ANTHROPIC_AUTH_TOKEN` or
  `ANTHROPIC_API_KEY` is non-empty, before runtime detection.
- `--help`, README (custom model endpoint, `settings.docker.json` alternative,
  threat model) document the requirement and the system-wide CA trust.
- `tests/test_api_optin.py` covers the unset and empty cases.

## Impact

- Specs: `external-cli-tools` (Custom model endpoint opt-in, MODIFIED).
- Code: `run.sh`, `README.md`, `tests/test_api_optin.py`.
