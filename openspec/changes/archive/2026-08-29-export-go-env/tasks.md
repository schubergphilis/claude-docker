## 1. Go environment

- [x] 1.1 Add an `ENV` instruction setting `GOBIN=/root/go/bin`,
  `GOPATH=/root/go`, `GOROOT=/usr/local/go`, placed after the tmux layer and
  before the existing runtime `ENV` block.
- [x] 1.2 Spell every path literally. Comment why `${HOME}` is wrong (Docker
  does not define `HOME` at build time, so `"${HOME}/go"` bakes in `/go`) and
  why `GOBIN` is not written as `${GOPATH}/bin` (Docker resolves the reference
  against the value from before the instruction, yielding `/bin`).
- [x] 1.3 Introduce no helper variable to work around the self-reference rule —
  nothing that `go env` does not recognise may ship in the session environment.

## 2. PATH

- [x] 2.1 Reorder the runtime `ENV` PATH to
  `"/usr/local/go/bin:${PATH}:/root/.local/bin:/root/go/bin"`.
- [x] 2.2 Rewrite the PATH comment: both trailing entries are agent-writable
  and volume-persisted, both sit after every system path, and neither may
  shadow a system binary. Drop any framing that treats `/root/.local/bin` as
  more trusted than `/root/go/bin`.
- [x] 2.3 Keep the `TASK_X_REMOTE_TASKFILES` comment recording why the opt-in
  is declined.

## 3. Smoke assertions

- [x] 3.1 Add `path_index()` to `smoke/assert-in-container.sh` — the index of
  an entry in the colon-separated PATH, `-1` when absent, matching whole
  entries only.
- [x] 3.2 Add `assert_path_before()` reporting through the existing
  `pass`/`fail` counters, failing distinctly when either entry is missing.
- [x] 3.3 Add `check_path_order()` asserting `/usr/local/go/bin` before
  `/usr/bin`, `/usr/bin` before `/root/.local/bin` and before `/root/go/bin`,
  and `command -v git` = `/usr/bin/git`.
- [x] 3.4 Assert `GOROOT`, `GOPATH`, `GOBIN` in the same function with the
  existing `assert_eq`.
- [x] 3.5 Call `check_path_order` from the Main dispatch after `check_security`
  and renumber the section banners that follow.

## 4. Verification

- [x] 4.1 `bash -n smoke/assert-in-container.sh` passes and the PATH helpers
  behave correctly against a synthetic PATH (ordered pair, reversed pair,
  missing entry).
- [ ] 4.2 `shellcheck run.sh entrypoint.sh smoke/*.sh` and
  `hadolint --config .hadolint.yaml Dockerfile` pass.
- [ ] 4.3 `docker build -t claude-code:local .` succeeds and
  `IMAGE=claude-code:local bash smoke/smoke.sh --uid="$(id -u)" --optins=aws,glab,tfe`
  passes, including the new `path-order` and `GO*` assertions.
- [ ] 4.4 Shadowing probe: plant an executable `git` in `/root/.local/bin` in a
  throwaway root volume, start a new container against it, and confirm
  `command -v git` still reports `/usr/bin/git`.
- [x] 4.5 `openspec validate export-go-env --strict` passes.
