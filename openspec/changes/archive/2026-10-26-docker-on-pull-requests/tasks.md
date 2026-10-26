## 1. Spec

- [x] 1.1 MODIFIED *The publishing pipeline does not gate merges*: runs on pull requests, never publishes from one, is not a required check, and a superseded pull-request run is cancelled
- [x] 1.2 `openspec validate docker-on-pull-requests --strict` passes

## 2. Workflows

- [x] 2.1 `docker.yml`: add a `pull_request` trigger for every base branch, so stacked pull requests are covered
- [x] 2.2 `docker.yml`: cancel an in-progress run only when it is a pull-request run
- [x] 2.3 `docker.yml`: replace the header comment that explained the missing `pull_request` trigger
