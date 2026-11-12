## Why

Inside the container every workspace is `/workspaces/<name>`, so when the agent points the user to a file it gives a path that doesn't exist on the host. The user has to translate it back to where the directory really lives before they can open it.

## What Changes

- New opt-in wrapper flag `--host-paths` (env `CLAUDE_DOCKER_HOST_PATHS=1`). With it, `run.sh` passes claude a short system-prompt addition that maps each `/workspaces/<name>` to its absolute host path (symlinks unresolved, in Windows form under Git Bash). The addition tells the agent to work through the `/workspaces` paths and to give the host path when it names a file for the user.
- claude keeps only the last `--append-system-prompt` it is given, so `run.sh` takes any `--append-system-prompt` the user passed after `--` out of the claude flags and puts the text of the last one after the map in a single flag. `--append-system-prompt-file` is left alone: claude combines one of those with one `--append-system-prompt`.
- A workspace whose host path or container path contains a control character is left out of the map, with a one-line warning. The container path is the basename of the resolved host path, so a symlink can carry a control character the typed path doesn't.

## Capabilities

- `multi-workspace-mounts`: ADDED *Host path map on request*.
- `cli-help`: MODIFIED *Help output enumerates every wrapper flag*: adds `--host-paths` and `CLAUDE_DOCKER_HOST_PATHS`.

## Impact

- Off by default. It grants no access: nothing extra is mounted or forwarded, and the host paths are text the agent can't act on.
- With it on, the host paths (username, directory layout, directory names) go to the model provider with every request and into the session transcript.
- Claude records a conversation's system prompt on its first request and reuses it on resume until compaction (observed on Claude Code 2.1.319), so a resumed session keeps the map it started with.
