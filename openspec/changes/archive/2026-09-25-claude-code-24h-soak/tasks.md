## 1. Spec & design

- [x] 1.1 Proposal, design, and `version-pin-refresh` delta for per-tool soak windows

## 2. Implementation

- [x] 2.1 `Tool.soak_days` (default `DEFAULT_SOAK_DAYS`); `claude-code` set to 1
- [x] 2.2 `--soak` defaults to `None`; resolution and `--audit` use the per-tool window unless `--soak` is given
- [x] 2.3 Report header states the effective window(s)
- [x] 2.4 `pins-updater.yml`: pass `--soak` only when the dispatch input is non-empty

## 3. Documentation

- [x] 3.1 README, Dockerfile comment, `ci.yml` comment

## 4. Verification

- [x] 4.1 Unit tests for the per-tool default, the override, and the audit window
- [x] 4.2 `openspec validate claude-code-24h-soak --strict`
