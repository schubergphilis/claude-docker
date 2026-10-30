## 1. Spec

- [x] 1.1 MODIFIED *Bind-mount host Claude config items* and *Container-specific settings file* (host-config-parity)
- [x] 1.2 MODIFIED overlay requirement, ADDED *Workspaces mount their physical path* (multi-workspace-mounts)
- [x] 1.3 `openspec validate launch-host-reads-nofollow --strict` passes

## 2. run.sh

- [x] 2.1 `cat_nofollow`, `one_hop`, `link_stays_inside`, `copy_tree_nofollow`, `stage_config_file` helpers
- [x] 2.2 `stage_git_overlays` and the `--glab` origin read use `cat_nofollow`; `core.autocrlf` validated
- [x] 2.3 `stage_host_config` stages every item as a copy
- [x] 2.4 `build_workspace_mounts` resolves with `pwd -P` and announces a symlinked workspace

## 3. Docs

- [x] 3.1 `docs/usage.md` *Host config parity* symlink rules, `.git/config` note; README workspace naming
- [x] 3.2 `docs/security.md` instruction-files bullet: what launch refuses, what remains

## 4. Verification

- [x] 4.1 BATS: one hop followed, chain refused, planted links skipped, swapped skill refused, CLAUDE.md/settings staged, `.git` link skipped, autocrlf validated, `link_stays_inside`, symlinked workspace
- [x] 4.2 BATS race tests: `.git/config` and `.git` swapped for links mid-read never leak
- [x] 4.3 Full BATS and unittest suites; shellcheck
- [x] 4.4 macOS (maintainer's host, 2026-10-28): `stat -L -f '%d:%i' /dev/fd/9` reports the opened file's inode but the fdesc device, so the open-file check compares inode only

## 5. Review follow-up (PR #224, 2026-10-30)

- [x] 5.1 An item that is itself a symlink gives its entries no hop (spec rule 2, scenario *A link planted in a linked item's target is not followed*)
- [x] 5.2 `ln -s --` for kept links, so a target starting with `-` isn't read as an option
- [x] 5.3 `unset CDPATH`, so `cd` into a relative config dir prints nothing into a staged file
- [x] 5.4 The `.git/config` stage file is created before the read, so a write error stops the launch instead of reading as a refused symlink
- [x] 5.5 BATS cases for each
