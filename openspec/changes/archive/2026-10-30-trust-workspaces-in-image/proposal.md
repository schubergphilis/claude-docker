## Why

On a macOS host, in-container git refused a workspace with `fatal: detected dubious ownership in repository at '/workspaces/<name>'`, although the workspace, its `.git` and every worktree were owned by the UID git ran as. Only Windows hosts got a `safe.directory` entry, passed as `GIT_CONFIG_*` env, so on Linux and macOS a misfiring ownership check stops git outright.

The failure is costly well beyond git itself. Agents work around it by appending `safe.directory` entries to `~/.gitconfig`, which lives in the persistent `claude-code-root` volume and so piles up across sessions and workspaces. They also `export GIT_CONFIG_COUNT=1 …`, which replaces any `GIT_CONFIG_*` set that `run.sh` passed. Scripts that start git with a cleaned environment drop the Windows env-based setting as well, and still fail.

Trusting every mount wholesale (`safe.directory = /workspaces/*`) would fix that, but it would also drop the protection the check exists for. A repository another host user owns (a shared or group-writable checkout, a teammate's repo mounted `--ro`) would then run that user's hooks or `core.fsmonitor` in the session, with every credential forwarded to it. Ownership is still meaningful on Linux and macOS hosts; only the container's view of it is unreliable.

## What Changes

- `run.sh` decides on the host which workspaces git may trust: one whose directory and `.git` (when present) belong to the user running it. Under Git Bash every workspace qualifies, since NTFS mounts carry no owner. A workspace another user owns gets a notice at start and no trust.
- `run.sh` passes the vouched-for container paths as `CLAUDE_DOCKER_TRUSTED_WORKSPACES`. The entrypoint, as root before the privilege drop, adds `safe.directory = /workspaces/<name>` and `/workspaces/<name>/*` to `/etc/gitconfig` for each, and refuses any other value (`*` included).
- System scope, so a session can't edit the entries, a `GIT_CONFIG_*` export that adds entries doesn't remove them, and git reads them regardless of its environment.
- `run.sh` no longer passes `GIT_CONFIG_*` for `safe.directory` on Windows, and the image carries no `safe.directory` of its own.

## Capabilities

- `container-runtime`:
  - MODIFIED *Windows hosts get a working in-container identity and git*: every workspace is vouched for, nothing goes through the env.
  - ADDED *In-container git trusts only the workspaces you own*.
  - ADDED *The entrypoint writes the vouched-for workspaces to system git config*.
- `external-cli-tools`: MODIFIED *Git credential helper per forge host*: the `GIT_CONFIG_*` list no longer carries `safe.directory` on Git Bash.

## Impact

- Linux/macOS: git no longer refuses a workspace you own on an owner mismatch, and still refuses one another user owns, as on the host.
- Windows: same behaviour as before, delivered through the entrypoint instead of the environment.
- Existing `safe.directory` entries in a warm `claude-code-root` volume are left alone. They become redundant, and the docs tell the user to delete them.

## Open question

This change doesn't explain the macOS failure itself: `stat` showed uid 502 throughout, the same uid git ran as. One candidate is the VM's file-sharing layer reporting a different owner, or failing a stat, which git treats as "not owned", for the worktree or common dir. Trusting the workspaces the host user owns makes git accept them whatever the cause.
