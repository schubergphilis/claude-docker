## 1. Token fallback in run.sh

- [x] 1.1 In the `--gh` env-var forwarding block, after attempting to forward
  `GH_TOKEN` / `GITHUB_TOKEN`, add a fallback: if neither was forwarded (both
  vars empty on the host), run `gh_token=$(gh auth token 2>/dev/null)` and, if
  non-empty, append `-e "GH_TOKEN=$gh_token"` to `ENV_ARGS`.
- [x] 1.2 Guard the `gh auth token` call so it only runs when `gh` is on PATH:
  `command -v gh >/dev/null 2>&1` before attempting the call.

## 2. Verification

- [x] 2.1 With `GH_TOKEN` exported: `claude-docker --gh ~/repo` — token forwarded
  from env, `gh auth token` NOT called.
- [x] 2.2 Without any token env var, with `gh auth login` done on host:
  `claude-docker --gh ~/repo` — `$GH_TOKEN` inside the container matches
  `gh auth token` output on the host.
- [x] 2.3 Without any token env var, without `gh` on PATH:
  `claude-docker --gh ~/repo` — container starts cleanly, no error printed,
  `$GH_TOKEN` is empty.
- [x] 2.4 Without any token env var, with `gh` on PATH but not logged in
  (`gh auth token` exits non-zero): container starts cleanly, no error printed.
