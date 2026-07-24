# Tasks — gh-auth-proxy-sidecar

## 1. Groundwork

- [x] 1.1 Select and digest-pin the Caddy image; record as `PROXY_IMAGE` default in `run.sh` with `CLAUDE_DOCKER_PROXY_IMAGE` override. **Gate before building further:** verify against the pinned image that (a) the local PKI root (`/data/caddy/pki/authorities/local/root.crt`) materializes at process startup with zero client traffic — if it is lazy, the design needs a run.sh warm-up request and this plan must be revised first; (b) `tls internal` on the three public hostnames triggers no ACME/outbound cert provisioning; (c) the root CA path is stable for the pinned version
- [x] 1.2 Verify `ca-certificates` (and `update-ca-certificates`) is present in the image; add to Dockerfile only if missing
- [x] 1.3 Flag parsing in `run.sh`: add `--gh-direct` (same token discovery as `--gh`, no sidecar); passing `--gh` and `--gh-direct` together exits with an error (same style as the existing unknown-flag exit); surface `gh-direct` as its own entry in `CLAUDE_DOCKER_FLAGS` so the statusline tag distinguishes it from proxied `gh`; update usage/help text

## 2. Sidecar lifecycle in run.sh

- [x] 2.1 Derive session id from the existing stage-dir suffix; define `claude-gh-<id>` network and `claude-gh-proxy-<id>` container names; extend the EXIT trap (bash-3.2-safe, single-quoted string pattern) with sidecar + network teardown **before any resource is created** — `rm -f`/`network rm` tolerate not-yet-existing resources, so the trap-then-create order closes the leak window
- [x] 2.2 Generate the Caddyfile into the stage dir: three site blocks (`github.com`, `api.github.com`, `uploads.github.com`), `tls internal`, `header_up Authorization` from `{env.GH_PROXY_BASIC}` / `{env.GH_PROXY_BEARER}`, JSON access log to stdout (live debugging via container logs; not persisted), default repo-deletion block matcher, optional `import` of the `CLAUDE_DOCKER_GH_POLICY` snippet (staged when set); include a test-only upstream-override env hook for the integration harness
- [x] 2.3 Compute the complete header values on the host and pass to the sidecar env only: `GH_PROXY_BEARER="Bearer <token>"` and `GH_PROXY_BASIC="Basic <base64 of x-access-token:<token>>"` — scheme prefix included; pipe base64 through `tr -d '\n'` (GNU base64 wraps at 76 chars, BSD does not)
- [x] 2.4 Start flow: `network create` → run sidecar (`--rm -d`, Caddyfile mounted `:ro`, no published ports) → retry-loop `$RUNTIME cp` of the root CA into the stage dir with ~15s timeout → `inspect` sidecar IP on the session network; print the sidecar container name at startup so the audit log stream is discoverable
- [x] 2.5 Wire the agent container: `--network claude-gh-<id>`, three `--add-host` entries, CA staged file mounted `:ro` at `/usr/local/share/ca-certificates/claude-docker-gh-proxy.crt`, `GH_TOKEN=claude-docker-proxy`, `NODE_EXTRA_CA_CERTS` set
- [x] 2.6 Fail-closed path: on sidecar start failure or CA timeout, remove sidecar + network and exit non-zero with an actionable error (never fall back to forwarding the real token)
- [x] 2.7 Best-effort startup prune of stale `claude-gh-*` containers/networks — backstop for hard-kill scenarios only; primary teardown is the early trap from 2.1
- [x] 2.8 Keep the no-token path silent and sidecar-free; keep `/root/.config/gh` tmpfs mask ON when the sidecar is active, OFF only for `--gh` without token and `--gh-direct`

## 3. Entrypoint

- [x] 3.1 In `entrypoint.sh`, when `/usr/local/share/ca-certificates/claude-docker-gh-proxy.crt` exists, run `update-ca-certificates` before the UID drop (root phase); tolerate absence silently

## 4. Verification

CI-runnable, credential-free integration harness (the existing `smoke/smoke.sh` reconstructs `docker run` itself and never exercises `run.sh`, so the sidecar lifecycle needs its own harness); real-credential assertions go to the manual checklist.

- [x] 4.1 Build a `run.sh`-driven integration harness (new script under `tests/`) that launches a mock GitHub upstream container and points the sidecar at it via the upstream-override hook from 2.2 — no credentials required, runnable in CI
- [x] 4.2 Harness: placeholder token visible in agent env, real (fake host) token absent; an API request from the agent reaches the mock with the injected `Authorization` header (also proves `gh`/Go's resolver honors the `--add-host` entries); `git clone` over HTTPS against the mock succeeds without a credential prompt; TLS verifies against the session CA
- [x] 4.3 Harness: `DELETE /repos/o/r` answered 403 with the policy body and never reaches the mock; benign requests pass; a `CLAUDE_DOCKER_GH_POLICY` snippet is enforced
- [x] 4.4 Harness: audit log — `$RUNTIME logs` on the sidecar shows structured entries with method/path/status; no log line contains the token; the sidecar name printed by 2.4 matches the running container
- [x] 4.5 Harness: two concurrent sessions get distinct sidecars/networks/CA roots and both function; teardown leaves no `claude-gh-*` containers or networks; trap-before-create ordering verified (kill run.sh between trap-set and sidecar start → nothing leaks)
- [x] 4.6 Harness: `--gh-direct` forwards the real token and starts no sidecar; `--gh` with no host token starts no sidecar and stays silent; `--gh --gh-direct` together exits with an error; sidecar start failure (bad image ref) exits non-zero without forwarding the token
- [x] 4.7 Manual checklist (extend the existing README checklist): real `gh api /user` via the proxy, private-repo HTTPS clone/push, git-LFS pull through the proxy (batch endpoint on `github.com` gets Basic injection; object transfer on pre-signed hosts bypasses), statusline shows `gh` vs `gh-direct`, podman parity (network create/inspect/cp/add-host), git-bash path handling for staged Caddyfile/CA mounts
- [x] 4.8 Run the existing smoke suite for regressions (aws/glab/tfe/registry paths untouched)

## 5. Documentation

- [x] 5.1 README: rewrite `--gh` row in the credential opt-in table, add `--gh-direct` row (including mutual exclusion and distinct statusline tag), add a "GitHub auth proxy" section — architecture, filtering + policy extension, audit log (viewable via the printed sidecar name, stdout-only, not persisted), limitations: certifi-style TLS clients, SSH remotes, custom-hostname GitHub (noting GHEC orgs on github.com are covered), git-LFS expected-working note
- [x] 5.2 README: update Threat model — GitHub token no longer exfiltratable from the agent container; live capability remains, bounded by sidecar policy; update the "if a session is compromised" rotation guidance
- [x] 5.3 README/pins docs: record that the Caddy image pin is deliberately manual and excluded from `update_pins.py` — upgrading the proxy is a reviewed change (changelog + config compatibility validation by a developer), not an automated bump
