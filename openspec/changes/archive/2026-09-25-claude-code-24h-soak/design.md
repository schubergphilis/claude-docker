## Context

`update_pins.py` holds one soak window, `DEFAULT_SOAK_DAYS = 7`, which can be
overridden with `--soak`. `pins-updater.yml` always passes `--soak`, defaulting
to `7`.

## Decisions

**Store the window per tool, on `Tool`.** `TOOLS` already records each tool's
probe and version regex. The soak window is another per-tool policy value, so
it goes in the same record. `soak_days` defaults to `DEFAULT_SOAK_DAYS`, so only
the exception (`claude-code`) has to set it.

**Treat `--soak` as a run-wide override, not a floor or a default.** When
`--soak N` is passed, every tool uses N for that run, including `claude-code`.
The alternative, per-tool windows scaled by `--soak`, is harder to reason about.
Keeping `--soak` uniform also leaves the meaning of existing invocations
unchanged. The argparse default becomes `None`, which means "use each tool's
own window".

**`pins-updater.yml` stops passing a default.** With `inputs.soak || '7'` the
scheduled run would always override `claude-code` back to 7 days. The input
default becomes empty, and `--soak` is added only when the operator fills in
the field.

**`--audit` follows the same rule.** CI calls `update_pins.py --audit` with no
arguments. If the audit kept a uniform 7-day window, it would reject every
`claude-code` pin between 1 and 7 days old that the refresh had just selected.

## Risks

A 24-hour window gives less time to catch a compromised `claude-code` release
before it lands in a pins PR. Two things limit that exposure. The pins PR is
still reviewed and built by a human before it merges. And CI's
`npm audit signatures` check, which verifies the npm registry signature on the
published package, runs regardless of the soak window.
