# claude-docker

Hardened Docker container for running Claude Code. Filesystem access is scoped to the directories you pass in; your host statusline, skills, agents, and commands come along via read-only bind-mounts.

## Install

```bash
# Build the image from your checkout (one-time; rerun after Dockerfile changes)
docker build -t claude-code:local ./claude-docker

# Put on your PATH
ln -s "$(pwd)/claude-docker/run.sh" ~/bin/claude-docker
```

## Usage

```bash
claude-docker                             # current dir as workspace
claude-docker ~/repo-a ~/repo-b           # multi-workspace
claude-docker --yolo ~/repo               # alias for --dangerously-skip-permissions
claude-docker ~/repo -- --resume          # any claude flag after --
```

### Credential opt-in

**Credentials are off by default.** No AWS / GitHub / GitLab config, tokens, or env vars reach the container unless you explicitly opt in:

| Flag         | Effect |
|--------------|--------|
| `--aws`      | Mount `~/.aws/config` + `~/.aws/sso` (:ro) and forward `AWS_PROFILE`/`AWS_REGION`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN`. |
| `--gh`       | Forward `GH_TOKEN`/`GITHUB_TOKEN`. (The `gh` CLI can still be logged in via in-container `gh auth login` persisted in the `claude-code-root` volume.) |
| `--glab`     | Mount the platform-appropriate `glab-cli` config dir (:ro) and forward `GITLAB_TOKEN`. |

Combine as needed: `claude-docker --aws --gh ~/repo`.

### Other hardening flags

| Flag            | Effect |
|-----------------|--------|
| `--ephemeral`   | Skip the `claude-code-root` and `claude-code-home` named volumes. No Claude OAuth token, `gh` login, or conversation history persists across runs. Use for one-shot sessions on untrusted workspaces. |
| `--ro`          | Mount every workspace read-only. Code review / audit mode. |

Example — review-only session on an untrusted repo, zero creds, no persistence:

```bash
claude-docker --ephemeral --ro ~/untrusted-repo
```

`claude --resume` + Ctrl+A lists sessions from every workspace you've ever used (shared Docker volume). In-container YOLO narrows the blast radius compared to running on the host, but see [Threat model](#threat-model) for what it does and doesn't protect.

## Host config parity

On every run, these items are dereferenced (symlinks resolved) and bind-mounted read-only into the container at the equivalent `/root/.claude/` path:

| Item                              | Purpose                             |
|-----------------------------------|-------------------------------------|
| `~/.claude/agents/`               | custom agent definitions            |
| `~/.claude/skills/`               | custom skills                       |
| `~/.claude/commands/`             | slash commands                      |
| `~/.claude/CLAUDE.md`             | global preferences (`gprefs`)       |
| `~/.claude/statusline-command.sh` | statusline renderer                 |

For `settings.json`, maintain a dedicated `~/.claude/settings.docker.json` (any valid Claude `settings.json` schema) — it's bind-mounted at `/root/.claude/settings.json` when present. Keeping it separate from your host `settings.json` avoids dragging macOS-only keys (`sandbox`, `env.SSL_CERT_FILE`, `enabledPlugins`) or host-filesystem `hooks` into the container. See [`examples/settings.docker.json`](examples/settings.docker.json) for a starting point.

The image sets `IS_SANDBOX=1` so `--yolo` / `--dangerously-skip-permissions` works despite running as root. See [Threat model](#threat-model) below.

## Auth model

Credentials are opt-in per run (see [Credential opt-in](#credential-opt-in) above). When enabled:

| Flag         | Source                                                      |
|--------------|-------------------------------------------------------------|
| `--gh`       | In-container `gh auth login` persists via `claude-code-root` volume (host macOS Keychain is not reachable). Host `GH_TOKEN`/`GITHUB_TOKEN` env vars are forwarded when set. |
| `--glab`     | Read-only bind-mount of `~/Library/Application Support/glab-cli` (macOS) or `~/.config/glab-cli` (Linux). Host `GITLAB_TOKEN` env var forwarded when set. |
| `--aws`      | Read-only bind-mount of `~/.aws/config` and `~/.aws/sso/` only. `~/.aws/credentials` (long-lived keys) and `~/.aws/cli/cache/` are **not** exposed. Host `AWS_PROFILE`/`AWS_REGION`/`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`/`AWS_SESSION_TOKEN` forwarded when set. |

### AWS SSO flow (`--aws`)

Standard SSO usage works unchanged: `aws sso login --profile X && export AWS_PROFILE=X` on the host, then `claude-docker --aws`. The container reads the short-lived SSO bearer token from `~/.aws/sso/cache` via the read-only mount.

If you'd rather not mount `sso/cache` either, flatten to env vars after login:

```bash
aws sso login --profile X
eval "$(aws configure export-credentials --profile X --format env)"
claude-docker --aws ...
```

Container then uses `AWS_ACCESS_KEY_ID`/`SECRET`/`SESSION_TOKEN` and the SSO cache is not needed inside. Temp creds freeze at container start (~1h TTL).

## Threat model

The container narrows blast radius vs. running `claude --yolo` on the host, but it is **not** a full sandbox:

- **Protected:** host filesystem outside your passed workspaces, host `~/.aws/credentials` (long-lived keys), host AWS/glab config dirs are read-only from inside (container can't persist changes back).
- **Exposed:** your passed workspaces are read-write; short-lived AWS SSO bearer tokens (`~/.aws/sso/cache`) and the glab config token are readable inside the container; `gh`/`GITLAB_TOKEN` env vars are readable; full outbound network.
- **Implication:** a prompt-injected file in any mounted workspace can exfiltrate those tokens and read/write any workspace. Don't mount repos you don't trust. Rotate tokens if the container is compromised.

Hardening applied: `--cap-drop ALL`, `--security-opt no-new-privileges`, pinned base image + app versions with sha256 verification on downloaded artifacts.

## Git worktrees

Sibling worktrees need a one-time repair inside the container because `.git` points to a host-absolute path:

```bash
# inside the container, in the worktree:
git worktree repair
```

## Split-pane agent teams

Set `CLAUDE_DOCKER_TMUX=1` to wrap `claude` in a container-local tmux session (required for Claude Code's split-pane teammates feature).

## Specs

Behavioural requirements live in [`openspec/specs/`](openspec/specs/); change history in [`openspec/changes/archive/`](openspec/changes/archive/).
