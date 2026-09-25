## Why

Every host Claude instruction surface reaches the container unverified (#81).
`run.sh` stages and bind-mounts, read-only, whatever is in
`$CLAUDE_CONFIG_DIR/agents/`, `commands/`, `skills/`, `CLAUDE.md`, and
`statusline-command.sh`. The last one is *executed*. Read-only stops the
container writing back. It says nothing about whether what went in is what was
approved. A workspace's own `CLAUDE.md` / `.claude/` is the same class of input,
arriving through the read-write workspace mount.

The issue asks for a decision, not an implementation: is host-side Sigstore
verification of these files before mount worth building, and if so in what
shape? It also names one defect that stands either way: the threat model does
not mention instruction files at all.

## What Changes

- Record the evaluation in `design.md`: threat addressed, tool options
  (cosign, sigstore-python, gitsign, plus a no-Sigstore hash alternative),
  keyless vs key-based, offline behaviour, and a recommendation.
- Add a threat-model bullet to `docs/security.md` § Threat model naming host config
  instruction files and workspace `CLAUDE.md` / `.claude/` as **trusted,
  unverified input**.
- No change to `run.sh`, the image, or any spec. `skip_specs: true`, because
  this change modifies no requirement. If the recommendation is later reversed,
  the implementing change adds a `host-config-parity` delta then.
- This change is left unarchived on purpose, until the maintainers accept or
  reverse the recommendation.

## Non-goals

- Implementing signature or hash verification in `run.sh`.
- Verifying workspace-supplied `CLAUDE.md` / `.claude/`.
- Adopting nono or any other external sandbox (see #75).
