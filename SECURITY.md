# Security policy

## Reporting a vulnerability

**Report privately, not as a public issue.** Use GitHub private vulnerability
reporting:

> **[Report a vulnerability](https://github.com/schubergphilis/claude-docker/security/advisories/new)**

That opens a draft advisory visible only to you and the maintainers. If you
cannot use it, open a public issue containing *only* a request for a private
channel — no details.

Please include the commit or release you tested, the wrapper flags in use
(`--yolo`, `--aws`, `--gh`, `--ephemeral`, …), which container runtime and host
OS, and a description of the weakness and its impact. Describe the *class* of
problem rather than attaching a working exploit, and never include real
credentials, tokens, or transcript content — a path, a mount mode, or a config
key is usually enough to make a finding reproducible.

This is a small project maintained on a best-effort basis. There is no bounty
and no guaranteed response time. Expect an acknowledgement and an initial
assessment; a fix lands as an ordinary PR, and the advisory is published once a
fix is available if publication adds anything for users.

## Supported versions

Pre-1.0. Fixes land on `main`; there are no backports to earlier pre-releases.

| Version              | Supported        |
| -------------------- | ---------------- |
| `main`               | Yes              |
| Latest `v0.1.0-rc.*` | Yes, best effort |
| Earlier pre-releases | No               |

Note that the image is built locally from this repository rather than pulled
from a registry, so "upgrading" means rebuilding — see
[Install](README.md#install).

## Scope

In scope: the `run.sh` wrapper, `entrypoint.sh`, the `Dockerfile` and the image
it produces, the credential opt-in model, the privilege drop and capability set,
the `gh` auth-proxy sidecar, and the persistent named-volume model.

Out of scope, because they are documented properties rather than defects — read
the [threat model](docs/security.md#threat-model) before reporting:

- **Full outbound network with no egress filtering.** There is no network
  policy; a session can reach anything the host can.
- **Runtime code-fetch.** `npx`, `pnpm dlx`, `uvx`, `tfenv install` and the Go
  toolchain fetch and execute third-party code on demand, by design.
- **Workspaces are read-write** unless `--ro` is passed.
- **Opted-in credentials are readable in-session.** That is what the flag does;
  the container is a blast-radius reduction, not a secret boundary.
- **State persists across sessions** in the `claude-code-root` and
  `claude-code-home` named volumes unless `--ephemeral` is passed.
- **`--yolo` / `--dangerously-skip-permissions` is a deliberate mode**, not a
  misconfiguration.
- **The container is not a full sandbox.** It narrows blast radius compared with
  running the agent directly on the host; it does not contain a determined
  attacker who already has code execution.

A finding that a *documented* boundary does not hold as documented is in scope
and welcome — that is different from reporting the documented boundary itself.

Vulnerabilities in Claude Code, or in the bundled third-party CLIs (`gh`,
`glab`, `aws`, `terraform`, `uv`, `pnpm`, …), belong upstream with their
respective projects. Known-vulnerable OS and language packages in the image are
tracked by the Trivy scans in the repository's CI workflows and, where a finding
is accepted for a time, recorded with a mandatory expiry in
[`.trivyignore`](.trivyignore).
