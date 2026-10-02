## 1. Spec & design

- [x] 1.1 Proposal, design, `api-egress-policy` spec, `cli-help` delta

## 2. Image

- [x] 2.1 `Dockerfile`: install `squid` from the Ubuntu archive (no new image, no pin)

## 3. run.sh

- [x] 3.1 `--api` turns the lock on; help text for `--api` and `CLAUDE_DOCKER_EGRESS_POLICY`
- [x] 3.2 `egress-policy.yaml` line reader and strict entry validation, before runtime detection
- [x] 3.3 Model-endpoint check against the policy
- [x] 3.4 `gen_egress_squid_conf` with the deny rules above the allowlist
- [x] 3.5 Internal + outbound networks, proxy sidecar, readiness wait, fail-closed aborts
- [x] 3.6 EXIT trap and stale prune extended; end-of-session denied-host summary
- [x] 3.7 `--gh` composition: gh sidecar joins the internal network; squid and agent `--add-host` point at it

## 4. Tests

- [x] 4.1 `tests/test_egress_policy.py`: parser rejections, missing file, unset policy, endpoint not listed, suffix match
- [x] 4.2 `smoke/assert-in-container.sh`: `check_egress` (listed reachable, unlisted and `api.anthropic.com` denied, proxy-unaware client and direct IP fail, no external DNS, metadata/loopback/private denied, gh composition)
- [x] 4.3 `smoke/egress.sh`: `run.sh`-driven cell; asserts the injection rejection, the no-policy abort, the denied-host summary and teardown
- [x] 4.4 `ci.yml`: plain and `--gh` cells

## 5. Docs

- [x] 5.1 README: API egress lock section, `--api` row, threat model; SECURITY.md scope

## 6. Verification

- [x] 6.1 `openspec validate api-egress-policy --strict`
- [ ] 6.2 CI green on the egress cells
