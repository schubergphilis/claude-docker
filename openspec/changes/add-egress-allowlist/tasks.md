# Tasks — add-egress-allowlist

## 1. Image

- [x] 1.1 Install `squid` (no-install-recommends) in the Dockerfile; verify the pinned base provides it and that `squid -v` runs

## 2. run.sh

- [x] 2.1 Parse `--egress-allowlist` and `CLAUDE_DOCKER_EGRESS` (reject unknown values); refuse podman; add `egress` to `CLAUDE_DOCKER_FLAGS`; update `print_help`
- [x] 2.2 Host validator (`[A-Za-z0-9.-]`, leading-dot suffix, ≤253, no empty label, no leading `-`, letter + inner-dot rules for untrusted tiers); `*.` hint
- [x] 2.3 Assemble tiers: base set, opt-in hosts, operator tier (`CLAUDE_DOCKER_EGRESS_ALLOW`, `ANTHROPIC_BASE_URL` host and port)
- [x] 2.4 Project file: parse, validate (abort on invalid line), normalise, SHA-256, approval store lookup / interactive prompt / non-interactive ignore; refuse a store inside a workspace
- [x] 2.5 Generate the squid config (ordered denies per design D6, `-n` domain ACLs, data files with an `.invalid` sentinel) into the stage dir, world-readable
- [x] 2.6 Lifecycle: names from stage suffix, trap extended before creation (gh sidecar first), prune extended; create internal + out networks, run sidecar (`--user proxy`, cap-drop ALL, nnp, `:ro` config), `network connect`, readiness loop with exited detection, read internal IP — every failure aborts
- [x] 2.7 Agent wiring: `--network` internal only, proxy env vars, `NO_PROXY`
- [x] 2.8 `--gh` composition: connect gh sidecar to the internal network, `--add-host` its internal IP, squid `hosts_file` + exact name/address allow for the three GitHub hosts (not `NO_PROXY`: suffix semantics); squid started after the gh block
- [x] 2.9 Capture agent exit code; print denied hosts from the sidecar access log with remediation; exit with the agent's code

## 3. Verification

- [x] 3.1 `smoke/assert-in-container.sh`: `check_egress` gated on `EXPECT_EGRESS` — allowed host reachable via proxy; non-allowlisted host 403; metadata IP 403; raw `--noproxy` client fails against an allowlisted host; external DNS fails; project host allowed/denied per `EXPECT_EGRESS_PROJECT`; GitHub denied without `--gh`, routed to the gh sidecar with it
- [x] 3.2 `smoke/smoke.sh`: `--egress=1` drives `run.sh` end-to-end (under `script` for the PTY) with declined / approved / recorded-approval passes, a `--gh` composition pass (fake token; api.github.com must verify against the session CA alone), an injection-line abort, and a `CLAUDE_DOCKER_EGRESS` typo rejection
- [x] 3.3 `ci.yml`: add the egress cell
- [x] 3.4 `shellcheck` clean; `openspec validate add-egress-allowlist --strict`

## 4. Docs

- [x] 4.1 README: flag tables, new "Egress allowlist" section (sources, file format, approval, denies, `--gh` composition, regressions, DNS ceiling, podman), threat model corrected in the three places plus `--ro` note
