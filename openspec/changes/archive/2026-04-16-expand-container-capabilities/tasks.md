## 1. Image: install external CLIs

- [x] 1.1 Add `gnupg`, `unzip` to base apt install
- [x] 1.2 Install `gh` via official apt repo with arch detection
- [x] 1.3 Install `glab` — fetch latest deb from GitLab releases API, arch-aware
- [x] 1.4 Install AWS CLI v2 — arch-aware installer URL (x86_64/aarch64)

## 2. run.sh: multi-workspace mounts

- [x] 2.1 Parse variadic args; default to `$PWD` when none given
- [x] 2.2 Resolve each arg to absolute path, mount at `/workspaces/<basename>`
- [x] 2.3 Set container cwd to the first workspace's container path
- [x] 2.4 Container path change `/workspace` → `/workspaces/<basename>`

## 3. run.sh: credential passthrough

- [x] 3.1 Bind-mount `~/.config/glab-cli` and `~/.aws` when present (RW)
- [x] 3.2 Forward `GH_TOKEN`, `GITHUB_TOKEN`, `GITLAB_TOKEN`, `AWS_PROFILE`, `AWS_REGION`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`, `AWS_SESSION_TOKEN` when set

## 4. Validate

- [x] 4.1 Rebuild: `docker build -t claude-code:local ~/claude-docker`
- [x] 4.2 Run with two dirs; confirm both mounted and writable
- [x] 4.3 `gh --version`, `glab --version`, `aws --version` all succeed in-container
- [x] 4.4 `glab auth status` works without re-auth when host config present
- [x] 4.5 `aws sts get-caller-identity` returns host identity when host creds present
- [x] 4.6 `gh auth login` inside container persists across a restart
- [x] 4.7 `claude --resume` + Ctrl+A shows sessions from all mounted workspaces
