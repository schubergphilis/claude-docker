## 1. Spec

- [x] 1.1 ADDED *The image is also scanned with the publishing pipeline's scanner and rules*
- [x] 1.2 ADDED *The publishing scanner's revision is checked against the publishing pipeline's*
- [x] 1.3 MODIFIED *Fixable high-severity findings block the merge; unfixed ones are reported*
- [x] 1.4 MODIFIED *Accepted risk is recorded with a reason and an expiry*
- [x] 1.5 `openspec validate grype-pr-gate --strict` passes

## 2. Workflows

- [x] 2.1 `ci.yml`: grype gates over `claude-docker:ci` and the checkout (HIGH+, unfixed included, `.grype.yaml`), as `mcvs-docker-action` runs them
- [x] 2.2 `image-scan.yml`: the same steps
- [x] 2.3 Pin `anchore/scan-action` to the revision `mcvs-docker-action` uses; Dependabot ignores it
- [x] 2.4 `tests/test_grype_gate.py`: the revision matches `docker.yml`'s pin and both workflows run the same steps

## 3. Docs

- [x] 3.1 `docs/security.md`: both scanners and gates, both accepted-finding files, where the expiry bounds an acceptance, how to unblock a red grype gate
- [x] 3.2 `docs/maintenance.md`: bump `anchore/scan-action` with `mcvs-docker-action`
