## MODIFIED Requirements

### Requirement: IS_SANDBOX env for root + dangerous-skip-permissions

The image SHALL set `IS_SANDBOX=1` so `claude --dangerously-skip-permissions` (and the `--yolo` shortcut) work in the legacy `HOST_UID=0` fall-through path where the entrypoint does not drop privileges. In steady state the entrypoint drops the container to the host UID before exec'ing claude, so the root-user check does not trigger and `IS_SANDBOX=1` is not load-bearing. The container narrows blast radius compared to using the flag on the host, but is not a full sandbox — see the project's threat-model documentation.

#### Scenario: YOLO works in container

- **WHEN** user runs `claude-docker --yolo`
- **THEN** `claude --dangerously-skip-permissions` launches without the root refusal error
