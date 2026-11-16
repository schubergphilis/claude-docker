## 1. Spec

- [x] 1.1 Proposal: the default policy leaves calls open that grant access outliving the session
- [x] 1.2 Spec delta: `gh-auth-proxy` "Request filtering policy" trimmed; new "Default policy blocks lasting grants and setting changes"

## 2. Implementation

- [x] 2.1 `run.sh`: four matchers in the `api.github.com` site (POST grants, PUT members, PATCH webhooks, PATCH settings), each with its numeric-id alias
- [x] 2.2 `docs/auth.md`: the blocked calls, the blind spots, the snippet-in-the-token-site note
- [x] 2.3 `docs/security.md`: threat-model line for `--gh`, persistence hunt in the incident checklist

## 3. Verification

- [x] 3.1 `tests/test_auth_proxy_caddyfile.py`: the gh site under a real Caddy; every blocked call, aliases, query, trailing slash, absolute form; ordinary calls pass; a user snippet still applies
- [x] 3.2 The new cases fail against `main`'s `run.sh`
- [x] 3.3 `tests/integration/gh-proxy-integration.sh`: one call per kind of grant is refused in a real session (runs in CI)
- [x] 3.4 `openspec validate gh-proxy-lasting-grants --strict`
