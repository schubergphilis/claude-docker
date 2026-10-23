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
- **Link the PR to the issue it resolves, if there is one.** Before opening a
  PR, search the open issues for the problem it solves
  (`gh issue list --search <keywords>`). Write `Closes #N` in the PR
  description: that is what links the PR to the issue (the issue's
  *Development* sidebar) and closes the issue on merge. A plain `Refs #N` or
  `Part of #N` only leaves a mention in the issue's timeline, so merged PRs
  that relied on one have left issues open after the work was done.
  - **The PR resolves only part of the issue?** Split the issue first: open a
    sub-issue for the part this PR finishes (add it under the original in the
    issue's *Sub-issues* panel, or with the `addSubIssue` GraphQL mutation via
    `gh api graphql`), and `Closes` the sub-issue. The original stays open for
    the rest.
  - **Stacked PRs:** `Closes` only fires when a PR merges into `main`, so merge
    a stack bottom-up and let GitHub retarget each next PR to `main`.
  - Keep the line current when later commits change the scope. If no issue
    exists, don't open one just to link it.
- **Never hand-edit `openspec/specs/`.** It is generated when a change is
  archived; fix the delta and re-archive.
- **Run the [local checks](CONTRIBUTING.md#local-checks-before-opening-a-pr)**
  before opening a PR.
- **Keep the container's security posture intact** — the privilege-drop,
  capability set, and credential opt-in model are load-bearing (see [Threat
  model](docs/security.md#threat-model)).

[`README.md`](README.md) is the quickstart; the reference material lives in
[`docs/`](docs/) — [auth](docs/auth.md), [security](docs/security.md),
[maintenance](docs/maintenance.md), [usage](docs/usage.md),
[installation](docs/installation.md), [scope](docs/scope.md).
