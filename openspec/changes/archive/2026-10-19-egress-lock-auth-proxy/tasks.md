# Tasks

- [x] 1.1 Accept `--api-direct` for `--egress-lock`; keep the `--api`-only checks of the auth-proxy change. Verify with bats: neither flag exits 1, `--api-direct` alone passes.
- [x] 1.2 Pin `http://claude-docker-api-proxy:8080` in the managed settings when the API sidecar is active, the host's `ANTHROPIC_BASE_URL` otherwise. Verify with bats for both.
- [x] 1.3 Attach the auth-proxy sidecar to the internal egress network and take its address there; keep the agent off `claude-auth-<id>`. Verify with bats (`network connect`, one `--network` on the agent, attach failure aborts).
- [x] 1.4 Map `claude-docker-api-proxy`, the GitHub names and the `--glab` host to the sidecar in squid's `/etc/hosts`, and allow 8080 / the `--glab` port for those names only, below the address denies. Verify with bats on the generated squid config.
- [x] 1.5 Share the "name served by the sidecar" check between `build_host_args` and squid's `CLAUDE_DOCKER_ADD_HOSTS` entries.
- [x] 1.6 Smoke: plain and `--gh` cells run `--api` and check the sidecar hop through squid and its log line; `--endpoint-port` runs `--api-direct`; teardown checks `claude-auth-*`. Verify with `tests/bats/egress.bats`.
- [x] 1.7 Run the three egress CI cells against a real image. Done in [run 39226147880](https://github.com/schubergphilis/claude-docker/actions/runs/39226147880) at `0cb759c`: plain (28 passed), `--gh` and `--endpoint-port` cells all PASS, each with no leftovers.
