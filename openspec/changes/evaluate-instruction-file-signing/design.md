## Context

`run.sh` copies `agents/`, `commands/`, `skills/` (dereferenced with `cp -RL`)
into a stage dir and bind-mounts them read-only. It mounts `CLAUDE.md` and
`statusline-command.sh` directly. The statusline script is wrapped so the
container prefixes the `docker:<flags>` tag and then *runs* the host script.
Nothing checks any of these files. Under `--yolo` there is no prompt between a
skill's instructions and a shell command.

Verification only means something if it happens **on the host, before the
mount is built**. A check inside the container would validate a file against a
policy that arrived by the same untrusted path.

## Threat addressed

| Threat | Does signing help? |
| --- | --- |
| Something on the host (a sync client, a compromised tool, another agent run on the host) silently edits `~/.claude/skills/…` or `statusline-command.sh` | **Yes**, as tamper-evidence: the file no longer matches a signature made by the expected identity. |
| `--claude-dir` pointed at a directory of unknown provenance | **Yes**, if the policy requires signatures for every mounted item. |
| A team wants proof that a session ran under the *reviewed* skill set | **Yes, but only with an approval process behind the signing identity.** This is where Sigstore's identity binding and Rekor log earn their cost. |
| The user edits a skill carelessly, then re-signs it | **No.** The signer is the editor, so signing proves "unchanged since I last signed" and nothing more. |
| Workspace `CLAUDE.md` / `.claude/` in a cloned repo | **No.** The host cannot hold signatures for arbitrary repos. Out of scope for any v1. |
| Prompt injection via workspace content, fetched pages, tool output | **No.** None of these is a file the wrapper mounts. |

For today's usage (one developer, their own `~/.claude`), the achievable
guarantee is tamper-evidence. That is real, but it does not need Sigstore.

## Options evaluated

Tool facts below come from the upstream docs:
[cosign `verify-blob`](https://github.com/sigstore/cosign/blob/main/doc/cosign_verify-blob.md),
[cosign `sign-blob`](https://github.com/sigstore/cosign/blob/main/doc/cosign_sign-blob.md),
[sigstore-python](https://github.com/sigstore/sigstore-python),
[gitsign](https://github.com/sigstore/gitsign).

### A. cosign (`sign-blob` / `verify-blob`)

- Sign: `cosign sign-blob <file> --bundle <file>.sigstore.json` (keyless, OIDC
  browser flow), or `cosign sign-blob --key cosign.key --bundle … <file>`.
- Verify keyless:
  `cosign verify-blob --bundle <b> --certificate-identity <id> --certificate-oidc-issuer <url> <file>`
  (`--certificate-identity-regexp` matches a pattern instead).
  Verify key-based: `cosign verify-blob --bundle <b> --key cosign.pub <file>`
  (`--key` also accepts KMS URIs).
- Offline: `--trusted-root <trusted_root.json>` points verification at locally
  held trust material, and the bundle carries the certificate and log inclusion
  proof. The documented `verify-blob` flags include no `--offline` switch, so an
  offline keyless check relies on the operator keeping that trusted root
  current. Key-based verification needs only the public key.
- Cost: a single static Go binary that the **host** must install. The image
  cannot supply it, because the check has to run before the container exists.
  That adds a host prerequisite to a wrapper whose only hard ones today are bash
  and a container runtime.

### B. sigstore-python (`sigstore sign` / `sigstore verify identity`)

- Sign: `sigstore sign [--bundle FILE] FILE…`.
- Verify:
  `sigstore verify identity --bundle <b> --cert-identity <id> --cert-oidc-issuer <url> FILE`.
  `--offline` is documented (it requires a bundle) and skips the trusted-root
  refresh that sigstore-python otherwise runs on every startup.
- Keyless only in the documented CLI surface. There is no key-pair mode.
- Cost: Python ≥ 3.10 plus `pip install sigstore` on the host. `uvx sigstore`
  avoids a global install, but it still needs uv on the host and fetches over
  the network at verify time unless cached.

### C. gitsign

- Signs **git commits and tags only**, not individual files. Verify with
  `gitsign verify --certificate-identity … --certificate-oidc-issuer …`; plain
  `git verify-commit` does not check identity. Rekor is required by default; an
  experimental `rekorMode = offline` embeds the verification data in the commit.
- Fit: this only works if `~/.claude` (or the `--claude-dir` target) is a git
  repo, and `run.sh` checks both that the working tree is clean **and** that
  `HEAD` is signed by the expected identity. That is the most natural shape for
  team distribution (a reviewed skills repo with signed merges). It is the least
  natural for the solo case: most `~/.claude` dirs are not repos, and `skills/`
  entries are often symlinks into *other* repos.

### D. Content-hash approval (no Sigstore)

- `run.sh` hashes every item it is about to mount and compares the hashes with
  an approved manifest on the host. It hashes after `cp -RL` staging, so
  symlink targets are covered. On a mismatch it **fails closed**, or, when
  interactive, shows the diff and asks for re-approval. Stdlib tools only
  (`sha256sum` / `shasum -a 256`).
- For the solo case this gives the same tamper-evidence as A and B, with no
  signing identity, no network, and no new host dependency. It shares its
  mechanism with the allowlist approval #75 proposes. It is also the only option
  that could cover workspace `CLAUDE.md`, by approving each repo on first use.
- It gives no cross-machine or organisational provenance.

### E. Nothing, plus a threat-model statement

- Name instruction files as trusted input, so users stop assuming that
  read-only means verified. Zero cost, and it fixes the documentation defect the
  issue calls out.

## Keyless vs key-based

| | Keyless (Fulcio + Rekor) | Key-based |
| --- | --- | --- |
| Identity | OIDC identity (email or CI workload) bound into a short-lived cert. Policy reads "signed by `x@org` via issuer `y`" | Whoever holds the private key |
| Key management | None for the signer | Generate, protect, rotate, and distribute the public key |
| Transparency | A public Rekor entry per signature: auditable, but it **publishes the signer identity and artifact digest** to a public log | None by default |
| Offline verify | Possible with a bundle plus a local trusted root; a stale trusted root is a failure mode | Trivial: public key only |
| Signing UX | Browser OIDC flow per signing session | Passphrase prompt |

Keyless is the right format **for team distribution**, the case nono targets:
provable evidence that production ran the approved policy. For a solo user it
costs a browser round-trip and a public log entry per skill edit, and buys no
guarantee beyond what a hash gives.

If built later: the constraints in #81, plus verify the staged (post-`cp -RL`) copy against
one signed manifest.

## Decision / recommendation

1. **Do E now** (this change): the threat-model bullet in `docs/security.md`.
2. **Do not build Sigstore verification now.** Today's users are single
   developers signing their own `~/.claude`. The guarantee achievable there is
   tamper-evidence, and D gives that without a signing identity, a host
   dependency, or a public log entry per edit. Building A, B, or C now would put
   the machinery ahead of the approval process that gives it meaning.
3. **If tamper-evidence is wanted, build D together with #75** as one
   content-hash approval mechanism, rather than as a separate feature here.
4. **Revisit Sigstore when a team distributes a reviewed skill set** (the
   inner-source direction, #3). At that point the shape is keyless cosign
   `verify-blob` over a single signed manifest, with `--certificate-identity` and
   `--certificate-oidc-issuer` pinned in the policy file and `--trusted-root` for
   offline hosts. gitsign fits instead if the skill set ships as a git repo.
   Either one fits the constraints above.
5. **Keep workspace `CLAUDE.md` / `.claude/` out of any signing scope.** The
   control for untrusted repos is the existing guidance: `--ephemeral --ro` and
   no credential flags. D's approve-on-first-use is the only mechanism that
   could extend to workspaces, and that belongs to #75.

## Open questions

- Do the maintainers accept (2)? If so, the Sigstore part of #81 can close as
  `wontfix` once this change is archived. If not, a follow-up change adds the
  `host-config-parity` requirement and the implementation per the constraints above.
