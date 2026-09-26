## 1. Fail closed

- [x] 1.1 `run.sh`: exit 1 under `--api` when neither `ANTHROPIC_AUTH_TOKEN` nor `ANTHROPIC_API_KEY` is non-empty, before runtime detection
- [x] 1.2 `--api` help text names the requirement
- [x] 1.3 `tests/test_api_optin.py`: unset and empty tokens are refused

## 2. Docs

- [x] 2.1 README: token requirement and why (OAuth token fallback)
- [x] 2.2 README: same trap on the `settings.docker.json` `env` route
- [x] 2.3 README: `CLAUDE_DOCKER_API_CA` is trusted system-wide (custom endpoint section and threat model)
