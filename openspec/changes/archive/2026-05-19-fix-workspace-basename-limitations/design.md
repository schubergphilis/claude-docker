## Context

`claude-docker/run.sh` validates each workspace basename against `*[!A-Za-z0-9._-]*|""` before passing it to `docker run -v $abs:/workspaces/$name`. The justification baked into the error message is that other characters "break `docker -v` parsing". This is overstated: `docker -v` uses `:` as the field separator and treats the rest of the value as a literal path. Spaces and other shell-metacharacters are inert *as long as the argv element is properly quoted*, which the script already does throughout (`MOUNT_ARGS+=("-v" "$abs:/workspaces/$name$ws_suffix")`, `-w "$CWD"`, `CMD+=("--add-dir" "${CONTAINER_PATHS[$i]}")`).

The cost of the over-broad allowlist surfaces every time a user `cd`s into a directory like `AI Policy` and runs `claude-docker`: the wrapper exits with an error, and the workaround (rename the directory, or `cd` somewhere else and pass the path explicitly) is friction without payoff.

## Goals / Non-Goals

**Goals:**
- Allow directory names containing spaces, parentheses, unicode, and other characters that work fine with quoted-argv passing through to docker/claude.
- Keep the only-really-broken cases rejected: `:` (genuine `docker -v` ambiguity) and empty basename (`/workspaces/` is meaningless).
- Preserve the existing collision-detection behavior unchanged.

**Non-Goals:**
- Supporting `:` in basenames via the `--mount` long syntax. Vanishingly rare in practice; would require rewriting the whole mount-building block.
- Sanitizing/rewriting the container-side basename. Host↔container name divergence creates collision risk and breaks user mental model ("the AI Policy workspace" should show up as `/workspaces/AI Policy`, not `/workspaces/AI_Policy`).
- Touching the persistent named-volume names (`claude-code-root`, `claude-code-home`). Those are fixed; only the per-workspace bind mount targets are affected.

## Decisions

### D1. Reject only `:` and empty, not an allowlist.

The current rule is a denylist disguised as an allowlist. We invert it to a real denylist of the genuinely broken characters.

```bash
case "$name" in
  *:*|"")
    echo "claude-docker: workspace basename '$name' cannot contain ':' (breaks docker -v parsing)" >&2
    exit 1 ;;
esac
```

**Alternatives considered:**

- **Sanitize to `_`**: Rewrite disallowed chars in the container-side basename only. Rejected because (a) host↔container name divergence is confusing when the user references "the AI Policy workspace" in chat — claude looks at `/workspaces/AI_Policy` and may not match, and (b) it introduces a real collision risk (`AI Policy` and `AI_Policy` both map to `AI_Policy`) that would require expanding the collision logic.
- **Switch to `--mount` syntax**: Use `--mount type=bind,src="$abs",dst="..."` which quotes individual fields and could in principle support `:`. Rejected as disproportionate — the only thing it unlocks is directory names containing `:`, which essentially nobody types on purpose, at the cost of rewriting the entire mount-building section (every conditional that appends to `MOUNT_ARGS`).
- **Keep the allowlist but extend it**: e.g., add space, parens. Rejected because every extension invites another bug report. Denylisting the genuinely-broken chars is a stable rule.

### D2. Leave newline/`\r` out of the denylist.

In theory, basenames containing newlines would break tools that read paths line-by-line. In practice, `basename "$abs"` cannot produce a newline-containing string unless the directory was created with extraordinary deliberation; the threat surface is not worth a defensive check. If a user manages to hit this, docker itself will fail with a clear error.

### D3. No changes to the README.

The current README does not document the allowlist (we checked). Loosening a constraint without prior user-facing mention requires no README update.

## Risks / Trade-offs

- **[Risk] In-container shell scripts assume `[a-z0-9-]` workspace names** → Mitigation: this is a self-imposed convention in user scripts, not a guarantee `claude-docker` ever made. The wrapper's contract is "mount your host directory at `/workspaces/<basename>`", which we now honor more faithfully. Any user script that breaks was relying on undocumented behavior.
- **[Risk] Display oddness in tools that don't quote paths** → Mitigation: any tool inside the container that mishandles spaces in paths is already broken for any subdirectory containing a space. Not a regression introduced by this change.
- **[Trade-off] Slightly more error message ambiguity** → The new message ("cannot contain `:`") is shorter but assumes the user understands why. Acceptable: the previous message claimed an allowlist that wasn't real.

## Migration Plan

None required. The change is strictly more permissive than the previous rule. Every basename that used to pass still passes; some that used to fail now pass; only the `:` and empty cases remain rejected. No persisted state, container names, or volume names depend on the basename character set.

Rollback: revert the single commit. No data implications.
