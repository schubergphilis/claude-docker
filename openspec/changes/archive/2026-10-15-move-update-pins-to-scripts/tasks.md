## 1. Spec

- [x] 1.1 MODIFIED the requirements whose scenarios run `uv run update_pins.py`
- [x] 1.2 `openspec validate move-update-pins-to-scripts --strict` passes

## 2. Move

- [x] 2.1 `git mv update_pins.py scripts/update_pins.py`; `REPO_DIR` resolves to the repository root
- [x] 2.2 Invocations in `pins-updater.yml`, `scripts/*.sh`, docs, Dockerfile comments, `pins/*.env` headers and the header template

## 3. Verification

- [x] 3.1 `python3 -m unittest discover -s tests -p 'test_*.py'` and `bats tests/bats` pass
- [x] 3.2 `python3 scripts/update_pins.py --list-tools` from the repository root reads every current pin
