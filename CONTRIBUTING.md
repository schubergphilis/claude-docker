# Contributing

Contributions to `claude-docker` are welcome from anyone.

## Workflow

1. Fork the repository and create a branch off `main` for your change.
2. Make your change. Keep the container's security posture intact — the
   privilege-drop, capability set, and credential opt-in model are load-bearing
   (see [Threat model](README.md#threat-model)).
3. Non-trivial behaviour changes are tracked with OpenSpec change proposals
   under [`openspec/changes/`](openspec/); follow the existing ones as a
   template.
4. Open a PR against `main`; a maintainer will review before it is merged.

By submitting a contribution, you agree that it is licensed under the
[Apache License 2.0](LICENSE), the same license as the project.

## Local checks before opening a PR

CI runs these on every PR; running them locally first is faster:

```bash
# Lint shell scripts and the Dockerfile
shellcheck run.sh entrypoint.sh smoke/*.sh
hadolint --config .hadolint.yaml Dockerfile

# Unit tests for the pin tooling
python3 -m unittest discover -s tests -p 'test_*.py' -v

# Build the image and run a smoke cell against it
docker build -t claude-code:local .
IMAGE=claude-code:local bash smoke/smoke.sh --uid="$(id -u)" --optins=aws,glab,tfe
```

See [`README.md`](README.md) for the full architecture, threat model, and the
version-pin refresh workflow (`update_pins.py`).
