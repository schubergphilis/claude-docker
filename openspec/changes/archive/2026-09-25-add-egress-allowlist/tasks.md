## 1. Spec & design

- [x] 1.1 Proposal, design, `egress-allowlist` spec, `cli-help` delta

## 2. Image

- [x] 2.1 `Dockerfile`: install `squid` from the Ubuntu archive (no new image, no pin)

## 3. run.sh

- [x] 3.1 `--egress-allowlist` flag, help text, `egress` in `CLAUDE_DOCKER_FLAGS`
- [x] 3.2 Allowlist assembly (base, `ANTHROPIC_BASE_URL` host, opt-in hosts, `CLAUDE_DOCKER_EGRESS_ALLOW`) and strict validation
- [x] 3.3 `gen_egress_squid_conf` with the deny rules above the allowlist
- [x] 3.4 Internal + outbound networks, proxy sidecar, readiness wait, fail-closed aborts
- [x] 3.5 EXIT trap and stale prune extended; end-of-session denied-host summary
- [x] 3.6 `--gh` composition: gh sidecar joins the internal network; squid and agent `--add-host` point at it

## 4. Tests

- [x] 4.1 `smoke/assert-in-container.sh`: `check_egress` (allowed reachable, denied 403, proxy-unaware client and direct IP fail, no external DNS, metadata/loopback/private denied, gh composition)
- [x] 4.2 `smoke/egress.sh`: `run.sh`-driven cell; asserts the denied-host summary, the injection rejection and teardown
- [x] 4.3 `ci.yml`: plain and `--gh` egress cells

## 5. Docs

- [x] 5.1 Docs: egress allowlist section and threat-model corrections in docs/security.md; README flag row and `--ro` note; `--registry` note in docs/auth.md

## 6. Verification

- [x] 6.1 `openspec validate add-egress-allowlist --strict`
- [x] 6.2 CI green on the egress cells
