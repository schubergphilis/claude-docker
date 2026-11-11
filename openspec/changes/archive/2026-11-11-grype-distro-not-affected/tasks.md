## 1. Spec

- [x] 1.1 MODIFIED `image-distribution`: *Accepted scanner findings are recorded and scoped*
- [x] 1.2 `openspec validate grype-distro-not-affected --strict` passes

## 2. Config and docs

- [x] 2.1 `.grype.yaml`: CVE-2026-123158 rule scoped to `openssh-client`, type `deb`, with its reason
- [x] 2.2 `docs/security.md` and `docs/installation.md` describe the exception

## 3. Archive

- [x] 3.1 Archive the change (syncs `openspec/specs/`)
