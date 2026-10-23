# Tasks

- [x] 1.1 `egress_save_log`: capture the engine's stderr, record the copy's exit status, and once the proxy was ready require squid's startup line in the copy. Print "missing or incomplete" with the reason instead of "egress log saved" otherwise. Verify with bats: copy fails, startup line rotated away, proxy never ready, and the startup line arriving on stdout (an engine that merges the streams). Check that breaking the check fails those tests.
- [x] 1.2 `start_egress_sidecar`: mark the proxy ready once `wait_sidecar` succeeds.
- [x] 1.3 Narrow the log claim in `docs/auth.md`, the `--egress-lock` help text and the `SECURITY.md` scope; document the warning under **Evidence**.
- [x] 1.4 Run the bats suite and shellcheck.
- [ ] 1.5 The egress smoke cells assert "egress log saved" on a real engine, so CI shows squid's startup line comes back from `docker logs`.
