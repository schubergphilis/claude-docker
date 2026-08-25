# Agent instructions

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) before changing anything. The parts
most often missed:

- **Behaviour or spec change? Draft the OpenSpec change first**, before writing
  the code — see [OpenSpec changes](CONTRIBUTING.md#openspec-changes). A small
  fix that leaves every spec as-is does not need one.
- **Never hand-edit `openspec/specs/`.** It is generated when a change is
  archived; fix the delta and re-archive.
- **Run the [local checks](CONTRIBUTING.md#local-checks-before-opening-a-pr)**
  before opening a PR.
- **Keep the container's security posture intact** — the privilege-drop,
  capability set, and credential opt-in model are load-bearing (see [Threat
  model](README.md#threat-model)).

Architecture, threat model, and the version-pin refresh workflow are in
[`README.md`](README.md).
