## 1. Wrapper

- [x] 1.1 `WITH_API=0` initializer and `--api) WITH_API=1 ;;` case arm in `run.sh`
- [x] 1.2 `--api` row in `print_help`, plus `CLAUDE_DOCKER_API_CA` under Environment
- [x] 1.3 Forward `ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_API_KEY ANTHROPIC_CUSTOM_HEADERS ANTHROPIC_MODEL ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_SMALL_FAST_MODEL` by bare name via `ENV_VARS` under `--api`
- [x] 1.4 Under `--api`, mount `CLAUDE_DOCKER_API_CA` read-only at `/usr/local/share/ca-certificates/claude-docker-api.crt`; exit with an error when it is set but not a file
- [x] 1.5 `api` statusline tag
- [x] 1.6 `entrypoint.sh`: run `update-ca-certificates` when either claude-docker CA file is present

## 2. Tests

- [x] 2.1 `smoke/smoke.sh`: `api` opt-in mounts a generated CA and sets `ANTHROPIC_BASE_URL`
- [x] 2.2 `smoke/assert-in-container.sh`: `check_api` asserts the env var is forwarded and the CA is in `/etc/ssl/certs/ca-certificates.crt` when granted, and neither when not
- [x] 2.3 CI: add `api` to the combined opt-in cell

## 3. Documentation

- [x] 3.1 README opt-in table row and statusline tag list
- [x] 3.2 docs/auth.md "Custom model endpoint" section: usage, private CA, `settings.docker.json` `env` alternative with plaintext caveat, Bedrock/Vertex deferral
- [x] 3.3 docs/security.md threat-model line: a custom endpoint receives all prompt content

## 4. Validation

- [x] 4.1 `openspec validate add-api-endpoint --strict`
- [x] 4.2 `./run.sh --help` lists `--api`
