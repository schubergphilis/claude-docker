## 1. Spec

- [x] 1.1 MODIFIED *Git over HTTPS opt-in*: Azure DevOps SSH rewrite
- [x] 1.2 `openspec validate git-https-azure-ssh --strict` passes

## 2. Wrapper

- [x] 2.1 `ws_git_config` helper, shared with `--glab` token discovery
- [x] 2.2 `az_ssh_rewrites`: per-project (Services) / per-collection (Server) `insteadOf`
- [x] 2.3 Help text

## 3. Tests and docs

- [x] 3.1 BATS test against real git for Services and Server
- [x] 3.2 README `--git-https` row
