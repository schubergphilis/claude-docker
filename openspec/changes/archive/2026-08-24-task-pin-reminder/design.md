## Context

`update_pins.py` splits the image's pinned tools into two classes:

```
  AUTOMATED (pins/<tool>.env, soak-gated, script rewrites)
    claude-code · openspec · pnpm · uv · glab · tfenv · awscli

  MANUAL (pinned in the Dockerfile, script only reports)
    nodejs        static line — "bump via the NodeSource note"
    go            resolves go.dev, reports pinned vs latest stable
    ubuntu base   resolves the registry, reports pinned vs current digest
    task          ← nothing at all
```

`task` (go-task) landed in `a86bf63` as `ARG TASK_VERSION=3.53.1` (`Dockerfile:27`)
with a hand-written `Bump with:` curl one-liner above it, but it was never wired
into `print_reminders()` (`update_pins.py:525`). It is the only pinned component
of the image that no tooling reports on. The failure mode is silent rather than
loud: Cloudsmith retains every published version in its pool, so a stale pin
keeps building successfully and forever.

`go` is the precedent this change follows — `openspec/specs/go-toolchain/spec.md`
already establishes the pattern of a manual pin that resolves upstream
best-effort and reports drift without ever rewriting the Dockerfile.

Observed facts about the source (verified against the live repo):

- `https://dl.cloudsmith.io/public/task/task/deb/ubuntu/dists/<suite>/main/binary-amd64/Packages.gz`
  is 2.4 KB gzipped and lists 17 versions, newest first.
- Every entry's `Filename:` sits under `pool/any-version/…`, confirming the
  Dockerfile's note that one pool is served under every suite path.
- `noble`, `plucky`, and `resolute` all return 200; a nonexistent suite returns
  404. The suite path is therefore load-bearing even though the pool behind it is
  shared.
- Versions in the index are plain semver (`3.53.1`, `3.46.4`).

## Goals / Non-Goals

**Goals:**

- A refresh run tells the operator whether `TASK_VERSION` is the newest version
  the apt repo actually serves.
- The reminder is indistinguishable in shape from the `go` and `ubuntu base`
  lines already in the block — an operator learns nothing new to read it.
- Resolution never fails a refresh run.
- `task` stays a manual pin; the Dockerfile keeps `ARG TASK_VERSION` and the
  script keeps never touching the Dockerfile.

**Non-Goals:**

- Promoting `task` to a soak-gated automated pin under `pins/`.
- Bumping the pin, in this change or automatically in any future run.
- Verifying the `.deb`'s bytes. Integrity comes from the signed apt repo, the
  same as `gh` and `nodejs`; nothing here adds a sha256 to a pin that has none.
- Wiring the reminder into CI. That is `automate-version-pins` task 8.2's
  territory and applies to every pin, not just this one.

## Decisions

### Report, don't automate

The soak window is the load-bearing policy of the automated path: a version is
selected only once it has survived N days in public. A Debian `Packages` index
carries no publish dates, so from this source there is nothing to soak against —
the same reason `go` stays manual (`go.dev`'s feed has no dates either).
Reporting is the honest ceiling of what this source supports.

*Alternative considered — full automation via GitHub release dates:* `go-task/task`
publishes dated GitHub releases, so a soak *is* computable from there, and
`task` could become a `pins/task.env` fragment carrying a version only (like the
npm tools, since apt verifies the bytes). Rejected for now: it splits one pin
across two sources of truth — dates from GitHub, availability from Cloudsmith —
and the two can disagree, since a GitHub release is published before Cloudsmith
ingests it. Getting that right means resolving from GitHub *and* confirming
presence in the index, i.e. a new tool kind rather than a reminder. That is a
worthwhile separate change; this one closes the reporting gap first.

### Resolve from the apt index, not GitHub releases

The reminder answers "is there a newer `task` I could pin?" — and a version the
build's `apt-get install task=<v>` cannot resolve is not one you can pin. Only
the apt index answers that question. A GitHub-release lookup would be cheaper
(existing `github` machinery, JSON, dates included) but can report a version
Cloudsmith has not ingested yet, sending the operator to a bump that fails the
build. The index is also the source the Dockerfile's existing `Bump with:`
comment already points at, so script and comment stay consistent.

### Derive the suite from the pinned base image

The Dockerfile's install uses `${VERSION_CODENAME}` from the base image's
`/etc/os-release`. The reminder mirrors that by parsing the codename out of the
pinned `FROM ubuntu:<codename>-<date>@sha256:<digest>` tag, rather than
hard-coding `resolute`.

Two reasons. A hard-coded suite silently rots: the base image bumps, the build
starts installing from a different suite, and the reminder keeps reporting the
old one. And because a nonexistent suite 404s, deriving the suite makes the
reminder's failure mirror a real build risk — if the derived suite is absent from
Cloudsmith, the build's own `apt-get update` would fail too, so "could not
resolve" is a signal worth seeing rather than noise.

*Alternative considered — a hard-coded suite with the pool's shared layout as
justification:* the pool genuinely is shared (`pool/any-version/…`), so any
valid suite returns the same version list, and hard-coding would be simpler and
never 404 on a base bump. Rejected because that simplicity is exactly what hides
the drift signal above.

### Parse the index directly, reusing existing helpers

`gzip` (stdlib, keeping `dependencies = []` intact) over the bytes from the
existing `http_bytes()` — which already enforces https-only with bounded,
credential-stripping redirects — then split the index on blank lines, keep the
stanzas whose `Package:` is exactly `task`, and hand their `Version:` values to
the existing `max_stable()`. That reuse buys the stable-only filter (`SEMVER_RE`)
and the numeric ordering for free, so a `-beta` entry or a non-newest-first index
cannot mislead the reminder. No `python-apt`, no `dpkg --compare-versions`
subprocess: the index is 17 short stanzas, and the only fields needed are
`Package:` and `Version:`.

Scoping to the `task` stanzas rather than scanning every `^Version:` line matters
for the guarantee above, not just for tidiness: today the repo publishes only
`task`, so a bare scan happens to be correct, but a second package landing in it
would feed *its* versions to a reminder whose whole promise is naming a version
`apt-get install task=<v>` can resolve. Stanza scoping also makes field order
within a stanza irrelevant.

Decompression is bounded (`GzipFile.read(INDEX_MAX_BYTES + 1)`, over-cap treated
as a failure) rather than `gzip.decompress()` on the whole response. These are
third-party bytes expanded inside a supply-chain tool, and the best-effort
`except Exception` that covers every other failure here cannot catch an OOM kill.
~100x headroom over today's 9 KB index, so the cap only fires on an upstream
layout change or an attack — and in both cases going quiet beats half-parsing.

`binary-amd64` is fetched, not both arches. Cloudsmith publishes the same version
set for each arch out of one pool, and this is a staleness reminder, not a pin —
a hypothetical arch skew would be a repo bug to notice at bump time, not
something a second 2 KB fetch per run should guard.

### Shape and placement

A new `task_latest_published()` returning `""` on any failure — the exact
contract `go_latest_stable()` and `ubuntu_current_digest()` already use — plus
one line in `print_reminders()`, ordered to match the Dockerfile's own ARG order
(`nodejs`, `task`, `go`, then the base digest). Since the function swallows
failures and the caller has a "could not resolve" branch, the best-effort
requirement holds structurally rather than by convention.

`print_reminders()` resolves the winning `FROM ubuntu` line once and derives both
the reported digest and the queried suite from that one line, instead of scanning
the Dockerfile text a second time inside `base_image_codename()`. The two scans
disagreed by construction — the caller keeps the last match, the helper returns on
the first — so a second `FROM ubuntu` (a multi-stage build) would have had the
task reminder querying one base image's suite while the digest line reported
another's. Single-stage today, so this is about not leaving the trap armed.

All four branches of the task line name the suite they spoke to, including the
drift branch: that is the branch whose reader is about to edit `TASK_VERSION`, so
it is the last one that should omit which suite the "newest" came from.

## Risks / Trade-offs

**The pinned base image's tag stops carrying a codename** (e.g. someone pins
`ubuntu:26.04@sha256:…`, where `26.04` is not a suite) → derivation yields a
token that 404s, and the reminder degrades to "could not resolve". Mitigation:
treat a derived token that is not a plausible codename (not purely alphabetic) as
unresolvable *without* a network call, and make the message name the token it
derived, so the cause reads as a parse problem rather than an outage.

**One more network dependency per refresh run** → a `dl.cloudsmith.io` outage
makes a run noisier. Mitigation: best-effort by construction — one ~2 KB request,
failure is a printed line, exit status untouched.

**Cloudsmith changes its repo layout or index compression** → the reminder goes
permanently quiet in the "could not resolve" state, which is a weaker failure
than a loud one. Accepted: the same exposure `go` and the base-digest reminders
already carry, and a reminder that fails the build on an upstream layout change
would be worse.

**A reminder is only as good as someone reading it** → this closes a silent gap
but still depends on a human running the script. That dependency is exactly what
`automate-version-pins` task 8.2 (weekly CI refresh opening a PR) exists to
remove, and this change makes `task` visible to that future job for free.

## Migration Plan

None. Nothing about the built image, its layers, or runtime behavior changes —
the diff is one script function, one printed line, and documentation. Rollback is
reverting the commit; the pin itself is untouched either way.

## Open Questions

- Should `print_reminders()` grow a non-zero exit or a `--check` mode when a
  manual pin is stale, so CI can gate on it? Out of scope here (it would change
  behavior for `nodejs`, `go`, and the base digest too), but worth deciding
  alongside 8.2.
