# Scope

[← Back to the README](../README.md)

claude-docker runs Claude Code in a container, with credentials off unless you opt in. See [Vision and scope](vision-and-scope.md) for what it is for and its principles. It doesn't:

- work without docker or podman,
- run agents other than Claude Code,
- isolate work on host files outside a container,
- apply per-path filesystem rules inside the container.

To add per-path rules inside the container, you can install a kernel-level sandbox such as [nono](https://github.com/nolabs-ai/nono) in a child image (see [Extending the image](usage.md#extending-the-image)).
