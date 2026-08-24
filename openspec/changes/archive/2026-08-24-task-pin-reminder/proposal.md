## Why

`task` (go-task) is a manual pin — `ARG TASK_VERSION=3.53.1` in the Dockerfile — but it is the only pinned tool in the image that `update_pins.py` says nothing about. The script's manual-pin reminder block covers `nodejs`, `go`, and the `ubuntu` base digest; `task` is absent, so a refresh run reports "wrote pins/*.env" while silently leaving one pin unexamined. Because Cloudsmith retains every published version, a stale `TASK_VERSION` never breaks the build — it just quietly ages, with nothing in the repo to surface it.

## What Changes

- Add a `task` line to `update_pins.py`'s manual-pin reminder block, printing the pinned version alongside the newest version actually published in the Cloudsmith apt repo, and flagging when the two differ.
- Resolve that newest version by fetching and parsing the repo's `Packages.gz` index — the same source the Dockerfile's existing `Bump with:` comment already points an operator at.
- Derive the index's dist codename from the pinned base image's tag, so the reminder queries the same suite the build's `apt-get` does.
- Keep resolution best-effort: a network, gzip, or parse failure degrades to a reminder that says the newest version could not be resolved, and never fails the refresh run.
- Keep `task` a manual pin. `TASK_VERSION` stays an `ARG` in the Dockerfile, no `pins/task.env` is created, and `update_pins.py` continues to never edit the Dockerfile.

Not in scope: promoting `task` to a soak-gated automated pin. The Debian `Packages` index carries no publish dates, so the soak window cannot be evaluated from it — the same reason `go` stays manual.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `version-pin-refresh`: adds a requirement that the `task` pin, like the other manual pins, is surfaced as an operator reminder reporting drift against the tool's apt repo. The capability's baseline arrives with the unarchived `automate-version-pins` change, so this change contributes an additive requirement rather than editing an existing one.

## Impact

- `update_pins.py` — a new resolver function plus one reminder line in `print_reminders()`; adds `gzip` (stdlib) to the imports. No change to the refresh/selection path, so no automated pin's behavior moves.
- `tests/test_update_pins.py` — unit coverage for index parsing and the degradation path.
- `Dockerfile` — comment only: the `task` block currently states that `update_pins.py` "leaves this alone", which stays true for rewriting but no longer for reporting.
- `README.md` — the "Updating pinned tool versions" section lists the manual pins; `task` joins that sentence.
- No change to the built image, its layers, or anything at runtime. The script gains one HTTPS request per run (~2 KB) to `dl.cloudsmith.io`.
