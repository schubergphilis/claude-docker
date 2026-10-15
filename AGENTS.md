# Agent instructions

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before changing anything. The parts
most often missed:

- **Check every PR against OpenSpec, not only the ones that look like
  behaviour changes.** Before you open a PR, and again before you push to one,
  search `openspec/specs/` for what the diff touches: file paths, workflow
  names and triggers, env vars, commands, documented outputs. Read every
  requirement that turns up. CI, docs and dependency changes count too. A
  workflow change can break a spec as easily as a code change can.
- **A requirement no longer holds? Draft the OpenSpec change first**, before
  writing the code — see [OpenSpec changes](CONTRIBUTING.md#openspec-changes).
  A change that leaves every spec as-is does not need one.
- **Record the result in the PR description's `OpenSpec` section** from the
  [PR template](.github/pull_request_template.md): the archived change, or
  `No spec change` with the specs you checked. Update it when later commits
  change the answer.
- **Link the related issue, if there is one.** Before opening a PR, search the
  open issues for the problem it solves (`gh issue list --search <keywords>`).
  Write `Closes #N` in the PR description when the PR resolves the issue, so
  GitHub closes it on merge, or `Refs #N` when it covers only part, and say on
  the issue what is left. Keep the line current when later commits change the
  scope. Merged PRs that named no issue have left issues open after the work
  was done. If no issue exists, don't open one just to link it.
- **Never hand-edit `openspec/specs/`.** It is generated when a change is
  archived; fix the delta and re-archive.
- **Run the [local checks](CONTRIBUTING.md#local-checks-before-opening-a-pr)**
  before opening a PR.
- **Keep the container's security posture intact** — the privilege-drop,
  capability set, and credential opt-in model are load-bearing (see [Threat
  model](docs/security.md#threat-model)).

[`README.md`](README.md) is the quickstart; the reference material lives in
[`docs/`](docs/) — [auth](docs/auth.md), [security](docs/security.md),
[maintenance](docs/maintenance.md), [usage](docs/usage.md).
