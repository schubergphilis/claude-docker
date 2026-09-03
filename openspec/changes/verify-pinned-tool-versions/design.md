## Context

See `proposal.md` — Why. The mechanics that constrain the approach:

- `update_pins.py`'s `TOOLS` is a list of `(name, kind, ref)` tuples, unpacked
  positionally at four sites. It already backs one CI consumer:
  `--list-npm-tools` emits TSV that the supply-chain audit step reads, with a
  fail-closed producer (validate every pin, then emit; never a partial table) and
  a documented consumer hazard — `$(...)` capture propagates a non-zero exit
  under `set -e`, `done < <(cmd)` does not.
- `ci.yml`'s `docker-build` job is the only place the image exists as a runnable
  local image; the build step `load: true`s it into the daemon and every later
  step in that job reuses it. A separate job gets a blank daemon.
- The image's `ENTRYPOINT` is `entrypoint.sh`, which `exec`s its arguments (or
  `runuser`s them as the dropped user). `docker run --rm claude-docker:ci <cmd>`
  therefore runs `<cmd>`; the existing claude-code step already depends on this.
- The seven automated tools are all on the default PATH unconditionally. The
  `aws`/`glab`/`tfe` opt-ins gate *credentials*, not the binaries, so every probe
  runs in a bare container with no opt-in.
- `update_pins.py` declares `dependencies = []` and is stdlib-only on purpose
  (`version-pin-refresh` — "Refresh tooling has no third-party runtime
  dependencies"). Nothing added here may change that.

## Goals / Non-Goals

**Goals:**

- One registry entry per tool carries everything needed to verify it, so adding a
  tool extends CI coverage with no CI edit.
- Fail closed on every path: unreadable version, unrunnable tool, missing pin.
- Report every failing tool in one run, not just the first.

**Non-Goals:**

- Teaching `update_pins.py` about containers. It stays a pin resolver that reads
  registries and writes fragments; the probing happens in CI, which already has
  the image. Beyond scope creep, a supply-chain tool with a docker dependency is
  a worse tool.
- Verifying anything about a tool beyond the version it reports — not its
  functionality, not its arch, not its provenance (the audit step owns that).

## Decisions

### The check lives in `docker-build`, replacing the claude-code step

Alternative considered: a new cell in `smoke/smoke.sh`. Rejected — `smoke.sh`
exercises entrypoint and privilege-drop behaviour across a UID/volume/opt-in
matrix, and each cell runs the whole entrypoint path. A version assertion is a
statement about image *contents*, needs exactly one bare container per tool, and
belongs next to the build that produced the image. `smoke.sh` also has to stay
bash-3.2/BSD-safe for local macOS runs; a CI-only step does not.

### `TOOLS` becomes a `NamedTuple`, gaining `probe` and `version_re`

Alternative considered: a sibling `VERSION_PROBES = {name: (probe, regex)}` dict,
leaving `TOOLS` untouched. Rejected — two tables keyed by tool name drift, and a
tool present in one and absent from the other is exactly the silent-skip failure
this change exists to remove. One record per tool makes the drift unrepresentable
instead of test-detectable.

Both options cost the same at the call sites: the four `for name, kind, ref in
TOOLS` unpackings break either way once the record grows, so the readability of
`t.name` / `t.probe` is free.

### Extraction is a per-tool regex with one capture group

Tool version output has no common shape:

```
pnpm      11.23.0
openspec  1.10.0
claude    2.1.241 (Claude Code)
uv        uv 0.12.5 (aarch64-unknown-linux-gnu)
glab      glab 1.114.0 (4d7c6cda7)
tfenv     tfenv 3.2.2
aws       aws-cli/2.36.29 Python/3.14.6 Linux/... exe/aarch64.ubuntu.26
```

Alternative considered: assert the pinned version appears anywhere in the output
as a substring. Rejected — it cannot tell a version from a coincidence.
`aws --version` carries a Python version and a distro version in the same line, so
a substring test for `2.36.29` passes if any of those three fields matches; and
`1.10.0` is a substring of `1.10.01`. Extracting the field, then comparing for
equality, is the only form that fails when it should.

Alternative considered: a field index (`awk '{print $2}'`). Rejected —
`aws-cli/2.36.29` has the version inside field 1, and a bare `11.23.0` has no
prefix at all.

Each rule is anchored on the tool's literal prefix and captures one field, and is
applied to the probe's stdout alone. Only the tool writes there: the entrypoint's
two diagnostics both go to stderr (`entrypoint.sh:43,80`), which is left to flow
into the step log. Note that bash's `[[ =~ ]]` has no multiline mode, so a rule
ending in `$` anchors against the whole capture — unexpected extra stdout makes
the match fail rather than be tolerated. That is the right direction for a check
whose job is to distrust the image, and it matches the strictness of the
whole-output equality test being replaced.

**`claude-code` keeps its suffix.** Today's step asserts the *entire* output
equals `<version> (Claude Code)`; the suffix is part of what proves a working
binary rather than a stub answering. Its rule anchors on that suffix
(`^([^ ]+) \(Claude Code\)$`) so generalising does not quietly weaken the one
assertion that already exists.

### The listing is TSV, and CI does the matching

`--list-tools` emits `name<TAB>probe<TAB>version_re<TAB>version`, mirroring
`--list-npm-tools`: fail-closed producer, consumed via `$(...)` capture and a
here-string, never a process substitution.

CI applies the regex with bash's `[[ =~ ]]` and reads `BASH_REMATCH[1]`. That
keeps the same string serving as both the Python-side rule and the shell-side
rule, so there is one rule per tool and not two. It constrains rules to the
subset both engines read identically — literals, `^`, `$`, `[^ ]+`, a single
group — which every rule above already is.

Alternative considered: `update_pins.py` growing a `--check-version` mode that
takes the captured output and does the comparison. Rejected — it would need the
container output piped back per tool, adding a Python process per tool for a
string match bash already does, and the exit-code plumbing gets worse, not
better.

`probe` is whitespace-separated argv, split deliberately into an array with
`read -ra` rather than left to unquoted word-splitting. No tool needs an argument
containing a space; a unit test holds that invariant.

### Failures accumulate, which `set -e` fights

Every tool is probed, then the step exits non-zero if any failed — the same shape
as `run_audit`'s `all_ok` and `assert-in-container.sh`'s per-check tally. A pin
bump that breaks three tools should say so once, not three CI runs in a row.

`set -euo pipefail` defeats this if written naively. A bare `out=$(docker run …)`
whose command exits non-zero is a simple command with a non-zero status, so the
shell exits *there* — and a tool that errors when invoked is precisely the
"installed but non-functional executable" case being tested. Every probe is
therefore run inside a conditional (`if out=$(…); then … else fail=1; fi`), which
is the context `set -e` exempts; `assert-in-container.sh` guards each of its
checks the same way and for the same reason.

The step echoes each tool's name, pinned version, and reported version on every
run, pass or fail — the existing claude-code step's unconditional
`echo "Expected: … Actual: …"` (`ci.yml:123`), kept and extended to seven tools.
A green run that logs nothing would make the next version-drift investigation
start from zero.

Only stdout is captured; stderr is left to flow into the step log. Merging them
would let entrypoint noise reach the regex, and an error message is more useful
in the log than in a capture that is about to fail a match anyway.

## Risks / Trade-offs

- **A tool changes its `--version` format upstream; extraction yields nothing and
  CI fails on a tool that is actually fine.** → Intended direction: unreadable is
  a failure, not a pass. The fix is a one-line rule change in the same registry,
  landing in the same PR as the pin bump that surfaced it.
- **Python `re` and bash ERE could read a rule differently.** → Rules are held to
  the common subset. A unit test asserts each rule has exactly one capture group
  and contains no construct outside that subset.
- **Unit tests match rules against recorded sample output, not live output, so a
  test can pass against a sample that no longer resembles reality.** → The CI
  step is the live check; the unit tests only guard the rule table against
  regression. This split is deliberate — the alternative is a unit test that
  needs a built image.
- **Seven extra `docker run` invocations in `docker-build`.** → Each is a
  sub-second start against an image already in the local daemon, against a build
  and a ten-cell smoke matrix. Not measurable.
- **A tool that writes its version to stderr would fail.** → All seven write to
  stdout. Correcting one that changes is a rule-and-probe edit in one place; the
  failure is loud.

## Migration Plan

Replace one CI step. No image change, no `pins/*.env` change, nothing a container
user can observe. The first `docker-build` run on the PR is itself the
verification that all seven rules match reality — a wrong rule fails the PR that
introduces it, not a later one. Rollback is a revert of the step.
