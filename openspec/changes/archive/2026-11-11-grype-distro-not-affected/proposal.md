## Why

Since the 2026-11-11 grype database update, the image gate fails on
CVE-2026-123158 in `openssh-client`. The CVE is a password-auth bypass in sshd
on musl libc without PAM. The image ships only the client, on glibc, and
Ubuntu marks every resolute openssh version not-affected, so no package update
will ever clear the finding.

The spec forbids scoping a suppression by vulnerability identifier, because
such a suppression expires silently once upstream fixes it, and covers none of
the next findings in the same component. Neither reason holds here: there is
no fix to wait for, and a rule that names the CVE is the only one that leaves
the next `openssh-client` finding enforced. Scoping by package name and type
alone would suppress every future openssh-client CVE.

## What Changes

- **image-distribution**: *Accepted scanner findings are recorded and scoped*
  allows one exception: a suppression scoped by vulnerability identifier, when
  the distribution marks the package not-affected for every version it ships.
  Such a rule also names the package and its type, so it covers that one
  finding in that one package.
- `.grype.yaml` gains that rule for CVE-2026-123158 in `openssh-client`.
- `docs/security.md` and `docs/installation.md` describe the exception.

## Capabilities

### Modified Capabilities

- `image-distribution`: *Accepted scanner findings are recorded and scoped*.

## Impact

- Changed: `.grype.yaml`, `docs/security.md`, `docs/installation.md`.
- No change to Trivy, which gates only fixable findings and already uses
  Ubuntu's data.
