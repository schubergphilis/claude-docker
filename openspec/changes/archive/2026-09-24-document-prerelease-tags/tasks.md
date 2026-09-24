## 1. Spec

- [x] 1.1 State the pre-release policy on *The image is published on a version tag* in
  `specs/image-distribution/spec.md`: pre-release tags publish on the same terms, cannot
  create or move a stable tag, and carry no support promise. Add the *a pre-release tag is
  pushed* and *the pre-release policy is documented* scenarios
- [x] 1.2 `openspec validate document-prerelease-tags --strict` passes

## 2. Docs

- [x] 2.1 Add the pre-release paragraph to `README.md` § *Prebuilt image from GHCR*, after
  the **Pin the full `v`-prefixed tag.** paragraph and before **Architectures.** — it is a
  tag-scheme caveat, so it belongs with the other tag-scheme prose rather than at the end
  of the section
- [x] 2.2 Name a real example (`v0.1.0-rc.6`) rather than a placeholder. Six of these are
  public right now, so a reader who arrived from the package listing can match what they
  are holding against what the paragraph describes

## 3. Verification

- [x] 3.1 Read the GHCR section top to bottom: pin rule → pre-releases → architectures →
  asymmetric scan → a red run publishes nothing. It should read as one list of caveats
- [x] 3.2 Confirm every relative link added by this change resolves. `lychee` is not in
  the image, so the four paths in `proposal.md` were resolved against the filesystem
  instead; the README paragraph adds no link. CI's link check covers the rest
- [x] 3.3 Not verifiable from here, and not needed: nothing in this change touches the
  workflow, so there is no pipeline behaviour to re-prove. The claim the prose rests on —
  that the six RC manifests are publicly pullable — was checked with an anonymous ghcr.io
  pull token returning `200` for `v0.1.0`, `v0.1.0-rc.1` and `v0.1.0-rc.6`

## 4. Housekeeping (operator, optional)

- [ ] 4.1 Delete the six `v0.1.0-rc.*` package versions from GHCR now that `v0.1.0` is
  released. Needs a token with `delete:packages`; out of reach of CI and of this change.
  Deliberately not a blocker — the trigger still matches pre-release tags, so this is
  cleanup of six artifacts, not a fix for the gap the spec now closes
