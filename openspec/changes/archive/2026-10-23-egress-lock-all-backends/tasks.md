# Tasks

- [x] 1.1 Pin all seven backend switches off in `gen_egress_managed_settings`. Verify with bats on the generated JSON and the in-container smoke check.
- [x] 1.2 Precedence harness: derive the `CLAUDE_CODE_USE_*` names from the image's bundle and fail on any that is neither pinned off nor listed as selecting no backend. Verify the check against the local 2.1.302 bundle.
- [x] 1.3 Precedence harness: add cases for Anthropic on AWS, Anthropic on Google Cloud, Mantle and gateway.
- [x] 1.4 Docs: `docs/auth.md` and the CI step comment name every backend, not three.
- [x] 1.5 Run the precedence harness against a real image in CI: every case, including the four new ones, passes, and the control run still reaches the override. Done in CI run 39915766138 on `42a671f`: all ten cases and all ten controls pass, and the seven switches are pinned off.
