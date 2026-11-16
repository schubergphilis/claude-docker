## Why

On Docker Desktop (macOS), `git rebase` and `git cherry-pick` in a session often abort on a clean working tree with "Your local changes to the following files would be overwritten" (#229). Git writes a file during the operation, and at the next step the file's stat data no longer matches the index, so git treats the file as modified. The workspace is a virtualised bind mount, where stat fields other than mtime seconds, size and mode are not stable between two reads of an untouched file.

The agent then spends turns on a tree it believes is dirty, or falls back to cherry-picking one commit at a time and retrying. `git update-index --refresh` beforehand doesn't help, because the mismatch appears partway through. `core.checkStat=minimal` does: 5 of 5 rebases succeed with it, against 1 of 5 (#229) and 3 of 5 (re-measured for this change) without.

## What Changes

- The entrypoint, as root before the privilege drop, sets `core.checkStat = minimal` in `/etc/gitconfig`, on every host.
- System scope, the same route as the `safe.directory` entries: a session's `GIT_CONFIG_*` export or a cleaned environment doesn't remove it, and the repo's `.git/config`, which the host's git shares, is not touched. #229 proposed `GIT_CONFIG_*` env; that predates `trust-workspaces-in-image`, which moved git settings out of the environment for these reasons, and it would contradict the `external-cli-tools` scenario *No forge flag, no helper* (no `GIT_CONFIG_*` env without a forge flag).
- A failed write is a warning, not a stop: without the setting git still works, only less reliably.

## Capabilities

- `container-runtime`: ADDED *In-container git compares minimal stat data*.

## Impact

- Every host, not only Docker Desktop: one behaviour to document and test, and other virtual or network filesystems have the same problem.
- Git in the container can miss an edit that keeps a file's size and lands in the same second as the last index update. That is the usual trade-off on such filesystems.
- Host git is unaffected. A user can go back with `git config --global core.checkStat default` in the container.
