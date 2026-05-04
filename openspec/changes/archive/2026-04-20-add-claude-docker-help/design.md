## Context

`run.sh` is a 160-line bash wrapper with a single argument-parsing loop that splits args at `--` (wrapper flags before, `claude` flags after). Flags recognised before `--` are: `--yolo`, `--ephemeral`, `--ro`, `--aws`, `--gh`, `--glab`, `--iterm`, `--tmux`; unknown non-flag args are treated as workspace paths. `CLAUDE_DOCKER_TMUX` env var also influences behaviour. Target compatibility includes macOS system bash 3.2 (explicit comments in `run.sh` about avoiding `${!arr[@]}`, associative arrays, and `[[ ]]` inside traps).

This change is small. A full design doc is borderline overkill — the few decisions worth recording are pass-through behaviour, exit semantics, and where to source the help text.

## Goals / Non-Goals

**Goals:**
- Invoking `claude-docker -h` or `claude-docker --help` anywhere before `--` prints usage and exits 0 without starting Docker.
- Help output enumerates every wrapper flag with a one-line description, plus the `--` separator, positional workspace args, and the `CLAUDE_DOCKER_TMUX` env var.
- Zero behavioural change for invocations that don't use `-h`/`--help`.

**Non-Goals:**
- Subcommand-style help (`claude-docker help <topic>`).
- Machine-readable output (`--help=json`, `--help-format`).
- `--version` — separate concern, not in scope.
- Auto-generated help from a flag registry — overkill for eight flags.

## Decisions

### 1. Detect `-h`/`--help` inside the existing arg loop, before `--`

Add a case branch alongside the other flag matches. When seen, call a `print_help` function and `exit 0` immediately — before workspace validation, mount construction, and `docker run`.

Alternative considered: pre-scan `"$@"` for `-h`/`--help` before the main loop. Rejected — adds a second pass, and the existing loop already tracks `saw_sep` so the "before `--`" check is free.

### 2. Flags after `--` are NOT intercepted

`claude-docker -- --help` still forwards `--help` to `claude` unchanged. The `--` separator contract is load-bearing; breaking it for a help flag would surprise users who rely on passthrough.

Alternative considered: intercept `--help` regardless of position. Rejected — violates the separator contract documented in the arg-parsing comment block at the top of `run.sh`.

### 3. Help text is a bash heredoc inline in `run.sh`

Use `cat <<'EOF' ... EOF` inside `print_help()`. Single-quoted delimiter prevents variable expansion surprises. Keeps help text close to the flag definitions so drift is visible in the same diff that adds/removes a flag.

Alternative considered: separate `HELP.txt` file bind-mounted or read at runtime. Rejected — adds a file to ship, and `run.sh` is the canonical CLI surface anyway.

Alternative considered: `printf` lines. Rejected — heredoc is more readable for multi-line usage text and equally bash-3.2-safe.

### 4. Exit 0, no workspace defaulting

When help is printed, return before the `[ "${#WORKSPACES[@]}" -eq 0 ] && WORKSPACES=("$PWD")` line runs. Help should be a pure side-effect-free print; no implicit `$PWD` mount setup, no `mktemp` staging dir.

### 5. Short flag `-h` included

`-h` is the universal convention. Cost is one extra `|` in the case pattern.

## Risks / Trade-offs

- **[Help drift]** Adding a new wrapper flag without updating the heredoc leaves help stale. → Mitigation: place `print_help` definition directly above the arg-parsing loop so reviewers see both in one hunk; add a line to the tasks list reminding future flag additions to update help.
- **[Accidental interception in unusual orderings]** If a user writes `claude-docker ~/repo --help` expecting the workspace arg to be taken literally, they'll hit help instead. → Mitigation: accepted. `-h`/`--help` as wrapper flags is the documented contract; users who want to pass `--help` to `claude` use `-- --help`.
- **[bash 3.2 heredoc quirks]** None known for single-quoted heredocs. Verified by inspection of existing `run.sh` which already uses set-u-guarded idioms for 3.2 compat; no heredocs currently present but the construct itself is 3.2-safe.
