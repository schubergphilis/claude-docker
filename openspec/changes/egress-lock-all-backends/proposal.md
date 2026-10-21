# Egress lock: pin every Claude Code backend off

## Why

Review of #101 (stefanwb item 1, dtump BLOCK at `run.sh:648`): the `--egress-lock` managed settings switch off Bedrock, Vertex and Foundry, but Claude Code also picks Anthropic on AWS, Anthropic on Google Cloud and Mantle, each with its own base-URL variable (`ANTHROPIC_AWS_BASE_URL`, `ANTHROPIC_GOOGLE_CLOUD_BASE_URL`, `ANTHROPIC_BEDROCK_MANTLE_BASE_URL`). A project `.claude/settings.json` that sets `CLAUDE_CODE_USE_ANTHROPIC_AWS` and `ANTHROPIC_AWS_BASE_URL` moves the model traffic off the endpoint with every managed switch in place.

Checked against the pinned Claude Code 2.1.302: the backend is picked by `xe()` in this order: gateway, then `CLAUDE_CODE_USE_BEDROCK`, `_FOUNDRY`, `_ANTHROPIC_AWS`, `_ANTHROPIC_GOOGLE_CLOUD`, `_MANTLE`, `_VERTEX`, else first party. The six switches are the bundle's provider-flag list. Gateway mode (`CLAUDE_CODE_USE_GATEWAY`) sends to `ANTHROPIC_BASE_URL`, which the lock already pins, so it isn't a bypass by itself; it is pinned off anyway, since a project has no reason to switch it on.

The list grows with Claude Code releases, so a hand-kept list alone won't hold.

## What Changes

- The managed settings pin all seven switches to `0`: `CLAUDE_CODE_USE_GATEWAY`, `_BEDROCK`, `_FOUNDRY`, `_ANTHROPIC_AWS`, `_ANTHROPIC_GOOGLE_CLOUD`, `_MANTLE`, `_VERTEX`.
- `tests/integration/managed-settings-precedence.sh` reads every `CLAUDE_CODE_USE_*` name from the image's Claude Code bundle and fails for each one that is neither pinned off nor on its short list of switches that pick no backend (`CCR_V2`, `COWORK_PLUGINS`, `NATIVE_FILE_SEARCH`, `POWERSHELL_TOOL` in 2.1.302). CI runs it on every PR, including the pin-refresh PRs, so a Claude Code release with a new backend fails the refresh until someone classifies the switch.
- New precedence cases for Anthropic on AWS, Anthropic on Google Cloud, Mantle and gateway.

## Capabilities

- `api-egress-policy`: MODIFIED (the managed-settings requirement).

## Impact

`run.sh`, `tests/bats/run.bats`, `tests/smoke/assert-in-container.sh`, `tests/integration/managed-settings-precedence.sh`, `.github/workflows/ci.yml` (step comment), `docs/auth.md`.
