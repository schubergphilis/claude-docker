## Context

The Dockerfile hand-authors every tool pin inline: a version `ARG` plus, for binary downloads, paired per-arch `sha256` `ARG`s (see `UV_VERSION`/`UV_SHA256_X86_64`/`UV_SHA256_AARCH64`, etc.). The existing in-file policy comment already states the intent — *"only pin versions ≥ 5 days old"* — implemented as human discipline. Two problems follow: (1) maintenance is error-prone (paired version+sha must move together, hashes computed by hand for two arches), and (2) because bumping is a chore, pins drift stale, which is itself a supply-chain risk.

A key realization shaped this design. The naive fix — "build with `latest`, then let the *image* age 7 days before use" — does **not** work: a built image is an immutable artifact, so a malicious version published at build time is already baked into the bytes; aging the image afterward changes nothing unless a promotion gate re-checks it. The soak only has teeth when applied to **version selection**, not to the built artifact. Selecting "the newest version already ≥7 days old" bakes the soak into the choice — every component has already survived in the wild before it enters an image, so the image is safe to use the moment it is built.

Constraints carried in from the codebase: builds must work on both `amd64` (ThinkPad/Windows) and `arm64` (Apple Silicon); the Dockerfile deliberately orders layers so a cheap pin (tfenv) doesn't bust an expensive layer (npm); npm-backed installs already trust npm's signed `dist.integrity` (no separate sha); the base image is digest-pinned (already best practice); apt packages float on Ubuntu's signed archive by choice.

## Goals / Non-Goals

**Goals:**
- Eliminate hand-authored versions and hand-computed SHAs for the automatable tools.
- Keep the supply-chain hardening: SHA-256 verification at build, hashes committed to version control (not fetched at build time).
- Bake a configurable soak window (default 7 days) into version *selection*, automatically.
- Make the refresh operator's experience clear: the script's report tells them exactly what changed, what was held back by the soak, and what still needs manual attention.
- Preserve Docker layer-cache granularity and the existing layer ordering.
- Keep `docker build .` self-contained (no required wrapper to inject build-args).
- Allow convenient one-off version overrides without hand-computing SHAs.

**Non-Goals:**
- No CI/cron automation, registry, or image promotion scheme in this change (the lockfile + script are reusable if/when that comes later).
- No persistent "freeze" mechanism for overrides — overrides are one-off.
- No change to apt package handling, the base-image digest mechanism, or any runtime/security behavior.
- Not automating NodeSource `nodejs` (apt-signed, and its publish dates aren't cleanly machine-readable for the soak) — manual with a reminder. Not automating the ubuntu base-image digest **on principle**, not convenience: it is the whole-OS surface, and promoting it deserves a deliberate, separately-reviewed decision rather than a daily auto-bump. The script flags drift but never rewrites it. (This distinction matters so a future engineer doesn't "fix" the base image into the automated path.)

## Decisions

### Decision 1: Soak the selection, not the image
Resolve each automated tool to the newest version whose publish date is older than the soak window, then pin + hash it. The soak window **defaults to 7 days**, superseding the Dockerfile's former hand-applied "≥ 5 days" comment; it remains configurable so the default is the only thing this decision fixes. **Alternative considered:** build at `latest` and age the image — rejected because aging an immutable artifact provides no real protection without a separate promotion-time re-check, and it sacrifices reproducibility.

### Decision 2: Pins live in per-tool lockfile fragments, consumed via COPY + source
Move pins from inline `ARG`s into `pins/<tool>.env` (sourceable shell assignments), one file per tool. The Dockerfile `COPY`s each fragment immediately before the `RUN` that uses it and `source`s it.
- **One file per tool, not one combined lockfile:** a single `COPY pins.lock` early would bust every downstream layer on any pin change; per-tool fragments keep cache granularity and respect the Dockerfile's deliberate layer ordering.
- **COPY + source, not `--build-arg` injection:** keeps `docker build .` self-contained and reproducible from repo state alone. **Trade-off:** `--build-arg` override is no longer the override path (replaced by Decision 5). This is the BREAKING change noted in the proposal.

### Decision 3: Automate by resolvability; the taxonomy draws the line
| Tool | Source | Soak date from | SHA in fragment? | Per-arch | Verdict |
|---|---|---|---|---|---|
| claude-code, openspec, pnpm | npm registry | publish time | no (npm integrity) | no | automate |
| uv, glab | GitHub release | `published_at` | yes | yes | automate |
| tfenv | GitHub release | `published_at` | yes | no (1 sha) | automate |
| aws-cli v2 | CDN zip | `aws/aws-cli` GitHub tag date | yes | yes | automate |
| nodejs | NodeSource apt | awkward (apt-signed) | no (apt sig) | no | manual + reminder |
| ubuntu base | digest | n/a — manual on principle | n/a (digest is the hash) | multi-arch index | manual + reminder |

npm tools carry **version only** — `npm install` verifies the registry-advertised `dist.integrity` hash, matching the current Dockerfile's trust model. This is registry-integrity, **not** independent provenance: a compromised registry serving a malicious tarball at the pinned version would still satisfy it. CI's `npm audit signatures` (run for all three npm tools) checks npm's keyring signature over that integrity, which is the closest available signal short of an independent attestation cross-check (a deferred follow-up). Only the four binary-download tools carry SHAs in the fragments.

### Decision 4: The report is the product
`update-pins` prints, per tool: `old → new` version, age, or `held` when a newer version exists but is still inside the soak window (this line makes the soak visibly *work*). Residual manual pins (nodejs, base image) are surfaced as `⚠ needs your eyes` lines at refresh time — including a note when the base tag's currently-resolved digest differs from the pinned one. The operator's loop is: run → review diff → build to test → commit.

The **base-image digest stays strictly manual**: the report only *flags* digest drift; the script never rewrites the `FROM` digest and exposes no `--pin base`. Promoting a new base image is a deliberate, separately-reviewed act, so it is left to the operator to edit the Dockerfile by hand. (`--pin`, per Decision 5, applies only to the automated tools.)

### Decision 5: Lightweight overrides, no freeze
`update-pins --pin <tool>=<version>` re-resolves and re-hashes a specific version, bypassing the soak, so an override never requires hand-computing a SHA. For the no-sha tools (npm, nodejs) a direct fragment edit is also trivial. **Alternative considered:** a persistent override/freeze layer that survives refreshes — deferred as premature; a durable divergence from "newest soaked" should be a visible, discussed change, not silent state.

### Decision 6: Newest stable version, majors included by default, with an opt-out
The soak filter selects the highest **stable** semver past the window — major bumps included (e.g. pnpm 10.x → 11.x) **by default**, uniform across all automated tools. Prereleases are excluded. **Why default-allow:** restricting to the current major would silently reintroduce staleness (a tool would never leave its pinned major without manual action — the exact manual drift this change exists to kill), and for a dev-box image "lagging behind" is worse than "an occasional breaking major," which the operator catches at build-to-test anyway. **Not a security trade:** crossing a major adds no attack surface — the soak simply offers no protection against a *legitimately released but behavior-changing* major. That is a stability risk, not a supply-chain one, so the mitigation is ergonomic, not a gate. **Guardrail + opt-out:** the report marks a major bump visually distinct from minor/patch lines (`⬆ MAJOR`) so it isn't rubber-stamped, and `--block-major-bumps` constrains a run to each tool's current major (falling back to the newest soaked version within that major, and reporting the crossed major as blocked). The durable way to hold one tool back remains `--pin <tool>=<version>`. **Alternative considered:** make blocking the default and require `--allow-major` to cross — rejected as inconsistent with the anti-staleness goal; the inverse default (`--block-major-bumps` opt-out) keeps freshness the easy path.

### Decision 7: Implement the refresh tool in Python (standard library only), run via uv
The refresh tool is written in Python using **only the standard library** (`urllib`, `json`, `hashlib`, `datetime`/`email.utils`, `subprocess`-free), shipped as a single `update_pins.py` with a PEP 723 inline-script header and run via `uv run`:

```python
#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
```

**Why Python:** the task is HTTP + JSON + version math + hashing. Python's standard library covers all of it directly — `urllib`, `json`, a small version-key sort, `hashlib`, `datetime`, and `tempfile` + `os.replace` for an atomic per-file fail-safe write — and the pure helpers are cleanly unit-testable with stdlib `unittest`.

**Why stdlib-only:** a supply-chain hardening tool should not itself pull third-party packages from PyPI. `dependencies = []` is declared in the header so the constraint is visible and enforced — adding a dep is a deliberate, reviewable edit.

**Why uv (not a bare `python3` shebang):** matches the repo's existing `uv` usage (CI's `check-frontmatter.py`), and `requires-python` pins the interpreter version for reproducibility across the Macs, Windows/WSL, and CI — value that survives even with zero dependencies.

The `pins/*.env` fragment format is plain sourceable shell, so **the Dockerfile consumes them directly** (`COPY` + source) with no dependency on the generator's language. **Alternatives considered:** a shell script (HTTP/JSON/version-sort/date math all fight the language — `jq` pipelines, `sort -V`, GNU/BSD `date` branching), Node/JS (no repo precedent, heavier dep story), and PowerShell Core (not installed by default on the macOS dev machines or CI, no precedent) — all rejected as worse fits than stdlib Python for this repo.

### Decision 8: Emit the resolved download URL into the fragment, not just the sha256
For each binary tool the fragment records, per architecture, the **download URL** the artifact was fetched from (`UV_URL_X86_64`, `GLAB_DEB_URL_AMD64`, `AWSCLI_URL_X86_64`, `TFENV_URL`, …) immediately followed by the sha256 of that URL's bytes; the Dockerfile sources the URL and `curl`s it directly instead of rebuilding the URL from the version and arch inline.

**Why:** without this, the download URL would be constructed independently in *two* places — `fragment_lines()` in the generator (which builds the URL, downloads it, and writes the hash) and the consuming `RUN` in the Dockerfile (which builds the URL again and verifies against that hash). The committed sha256 only proved "the bytes the generator hashed match the bytes the build fetched" *if both sides happened to assemble the identical URL* — an invariant nothing enforced. A change to a URL template on one side (a vendor path change, an arch-token rename) would silently diverge: the generator hashes URL-A, the build fetches URL-B, and the mismatch surfaces only at `docker build` time (caught by `sha256sum -c`, but late and only when a human happens to build), not at refresh time. Single-sourcing the URL into the fragment makes the sha256 **provably cover the exact artifact the build fetches**, and collapses the duplicated arch→URL logic to one place. **Trade-off:** fragments carry a few more lines; the consuming `RUN` blocks get simpler (a `case` that selects `URL`+`SHA`, then `curl "$URL"`). ARCH detection still drives any path *inside* an archive (e.g. `uv-<arch>-unknown-linux-gnu/`), which is not a download URL. **Alternative considered:** a CI job that regenerates fragments against mocked HTTP and diffs them against the Dockerfile's expectations — that *detects* drift after the fact with extra machinery, whereas emitting the URL *removes the possibility of drift*; prevention over detection. This applies only to the four binary tools — the npm tools have no build-side download URL to single-source (npm resolves them).

## Risks / Trade-offs

- **Network/API dependence at refresh time** → the script fails loudly and leaves the existing fragments untouched; a failed refresh never produces a half-written lockfile.
- **`--pin` bypasses the soak** → by design, but the report must clearly mark an overridden tool so it isn't mistaken for a soaked resolution.
- **Per-arch SHA fetch runs on a single machine** → the script downloads *both* arch artifacts regardless of host arch; a tool that stops publishing one arch must surface as an error, not a silent single-arch pin.
- **Layer-cache regression if fragments are COPY'd too early** → mitigated by COPYing each fragment immediately before its consuming `RUN`, preserving today's ordering.
- **BREAKING: `--build-arg` override removed** → documented in README; replaced by `--pin` and direct edits for no-sha tools.
- **Residual manual pins can still rot** → the `⚠` reminders fire on every refresh so they stay in front of the operator rather than being silently forgotten.

## Migration Plan

1. Add `update-pins` and generate the initial `pins/*.env` fragments from the versions currently in the Dockerfile (or freshly soak-resolved).
2. Refactor the Dockerfile to COPY + source fragments, removing the automated tools' inline `ARG`s; keep nodejs and the base-image digest inline.
3. Verify a clean `docker build .` on both arches produces an equivalent image.
4. Update README with the refresh workflow, soak, overrides, and the residual manual pins.

Rollback: revert the Dockerfile and delete `pins/` — the hand-authored `ARG` form is recoverable from git history.
