## 1. Implement help in run.sh

- [x] 1.1 Add `print_help()` function with a single-quoted heredoc covering every wrapper flag (`--yolo`, `--ephemeral`, `--ro`, `--aws`, `--gh`, `--glab`, `--iterm`, `--tmux`, `-h`/`--help`), the `--` separator semantics, positional workspace behaviour (default = `$PWD`), and the `CLAUDE_DOCKER_TMUX` env var with its `1`/`cc` values
- [x] 1.2 Add `-h|--help` case branch to the existing `for arg in "$@"` loop, positioned so it only fires before `saw_sep=1` (after the `--` check)
- [x] 1.3 On match, call `print_help` and `exit 0` immediately — before workspace defaulting, `mktemp` staging, and `docker run`

## 2. Verify against spec scenarios

- [x] 2.1 `claude-docker --help` prints usage and exits 0 with no docker process
- [x] 2.2 `claude-docker -h` prints usage and exits 0
- [x] 2.3 `claude-docker --aws --gh --help ~/repo` prints usage, exits 0, and leaves no `claude-docker-host.*` dir under `$TMPDIR`
- [x] 2.4 `claude-docker -- --help` forwards `--help` to `claude` inside the container (no local help printed)
- [x] 2.5 `claude-docker ~/repo -- -h` forwards `-h` to `claude` inside the container
- [x] 2.6 Help output contains every wrapper flag name AND a description line for each
- [x] 2.7 `claude-docker --help` succeeds with exit 0 even when `docker` is not on PATH

## 3. Update docs

- [x] 3.1 Add a "Help" section to `claude-docker/README.md` pointing at `claude-docker --help` as the canonical flag reference
- [x] 3.2 Add a comment above `print_help()` reminding future flag additions to update both the parsing loop and the help heredoc in the same diff
