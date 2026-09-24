## Why

[`.github/workflows/docker.yml`](../../../.github/workflows/docker.yml) publishes on
`tags: [v*]`. That glob does not distinguish a release candidate from a release, so the
six tags cut to exercise the pipeline during
[#40](https://github.com/schubergphilis/claude-docker/pull/40) — `v0.1.0-rc.1` through
`v0.1.0-rc.6` — each published a real package, and all six are public today: an anonymous
pull token fetches every one of their manifests with a `200`.

The mechanism earned its keep. Verifying a multi-arch push against the registry rather
than against a workflow log needs a pullable image, and this is how #40 got one. It is
also not dangerous: tagging is `docker/metadata-action`'s `type=ref` under
`flavor: latest=false`, so an RC publishes exactly `:v0.1.0-rc.N` and can never move
`latest` or shadow a stable tag.

What is missing is that nothing states what an RC tag *promises*. Both places a consumer
would look are silent — [`openspec/specs/image-distribution/spec.md`](../../specs/image-distribution/spec.md)
says "version tag" throughout and draws no stable/pre-release distinction, and
[`README.md`](../../../README.md) § *Prebuilt image from GHCR* documents `:v0.1.0` and
the pin-the-full-tag rule without mentioning pre-releases at all. Someone who finds
`v0.1.0-rc.4` in the package listing gets a real, public, multi-arch image that passed
the same scan gate a release does, with nothing telling them it is not one. The practical
policy — an RC is unsupported; hit a bug on one and move to the latest stable tag — is
understood by the people who cut those tags and written down nowhere.

So today's behaviour is true by accident of the glob rather than by decision. This change
makes it a decision.

Closes [#78](https://github.com/schubergphilis/claude-docker/issues/78).

## What Changes

- **State the pre-release policy in the `image-distribution` spec**, on the requirement
  that already owns the publish trigger. The version-tag trigger covers pre-release tags;
  a pre-release publishes under its own verbatim tag and cannot create or move a stable
  one; and it carries no support promise. The documentation scenario sits on the same
  requirement, following the spec's own precedent of pairing *the failure mode is
  documented* with the gating requirement it describes.
- **Add one paragraph to `README.md` § *Prebuilt image from GHCR***, after the
  pin-the-full-tag paragraph and in the same bolded-lead style as its neighbours: RC tags
  are published by the same pipeline through the same scan gate, they exist to verify a
  candidate before a release is committed to, they are unsupported, and a bug found on one
  should be retried against the latest stable tag rather than fixed against the RC.

Not in scope:

- **Changing `docker.yml`.** Tightening `tags:` to exclude pre-releases would remove the
  verification path that made #40 checkable in the first place. This is a documentation
  gap, not a bug in the workflow.
- **Deleting the six published `v0.1.0-rc.*` packages.** Housekeeping, and it does not
  close the gap: the trigger is unchanged, so the next RC republishes. Tracked in
  [`openspec/changes/archive/2026-09-23-publish-image-to-ghcr/tasks.md`](../archive/2026-09-23-publish-image-to-ghcr/tasks.md);
  deleting a GHCR package version needs an operator token with `delete:packages`.
- **A `design.md`.** There is no design here beyond the choice already argued above —
  document rather than restrict — and a second file restating it would be the only
  content in it.

## Capabilities

- `image-distribution` — MODIFIED: *The image is published on a version tag* gains the
  pre-release policy and two scenarios.

## Impact

- Documentation only. No change to the workflow, the image, the wrapper or any pin, and
  no change to what the pipeline publishes or when.
