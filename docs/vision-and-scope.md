# Vision and scope

[← Back to the README](../README.md)

## Vision

claude-docker is where Claude Code does the hands-on work, writing code and more, while people steer it at the level of intent and behaviour. It gives the agent what it needs, narrows what it can reach on your machine, and plugs into the tools and integrations you already use.

## Principles

- **Narrow the blast radius, don't claim a sandbox.** The container limits what a session can reach on your machine. It is not a full sandbox, and every trade-off is written down in the [threat model](security.md#threat-model).
- **No flag weakens the container's hardening.** Options add access, such as credentials or endpoints, never privileges inside the container.
- **Open and lean by default.** Your Claude Code setup comes along, the network is open, and the image ships a small set of pinned tools. No host credentials come along, and nothing project-specific is added.
- **Everything else is opt-in, per integration.** Credentials, model backends and session modes each sit behind their own flag.
- **Tools for the agent, not runtimes for your project.** The image carries the tools the agent needs to work with code, Git forges and clouds. Your project's language runtimes are fetched per project (Terraform, Python) or go in a child image. Node ships because Claude Code needs it.
- **Add capability only when it's needed.** A new tool or integration goes into the base image when the child image isn't a reasonable route.
- **Decide together.** New capability and changes to this page are discussed openly and decided by consent of the maintainers.
- **Keep up with Claude Code.** A weekly job proposes refreshed pins, Claude Code included, so the agent works with current releases.
- **Build it the way it's meant to be used.** Changes are reviewed as intent and behaviour ([OpenSpec](../openspec/specs/)). A significant change has its OpenSpec change reviewed before the code is written. A smaller behaviour change brings its OpenSpec change and the code in one PR. Bug fixes and documentation updates need no OpenSpec change.

## Scope

This section describes what claude-docker is today, at the level of categories. Update it when a category is added or dropped, not for each flag.

### Who it's for

People running Claude Code on their own machine: macOS, Linux or Windows.

### Default and options

| Layer | What it covers |
|---|---|
| Default | No host credentials. Your Claude Code setup (skills, agents, commands, themes, `CLAUDE.md`, statusline) read-only, plus a settings file of your choice copied in at start. The workspaces you pass in, read-write. Open network. Login and history persist between sessions. Claude Code asks before it acts. |
| Options | Credentials per integration (Git forges, clouds, package registries). A custom model endpoint, optionally locked, and restricted egress to a host allowlist (the boundary is the internal network and proxy sidecar outside the agent container, so a child image can't add it). Read-only workspaces. Sessions that keep nothing. Unattended mode. Terminal split panes and alternate Claude config dirs. Your own image built on top of this one. |

The [README](../README.md) and `claude-docker --help` list the flags.

### Out of scope

- **A development environment for people.** It is one for the agent. It is not an IDE and doesn't try to become one; connecting it to your IDE is fine.
- **Your project's language runtimes.** Use a [child image](usage.md#extending-the-image).
- **A security boundary for hostile code.** See the [threat model](security.md#threat-model).
- **Agents other than Claude Code.**
- **Running without Docker or Podman**, or isolating work on host files outside a container.
- **Per-path filesystem rules inside the container.** A kernel-level sandbox such as [nono](https://github.com/nolabs-ai/nono) can add them in a child image.
