## REMOVED Requirements

### Requirement: Pinned Go toolchain installed on the default PATH
**Reason**: Go is a project language runtime, not a tool the agent needs (`docs/vision-and-scope.md`); it leaves the base image (#219).
**Migration**: Install Go in a child image (`CLAUDE_DOCKER_IMAGE`); `docs/usage.md` has a recipe.

### Requirement: Go tarball pinned by version and sha256-verified
**Reason**: Go is a project language runtime, not a tool the agent needs (`docs/vision-and-scope.md`); it leaves the base image (#219).
**Migration**: Install Go in a child image (`CLAUDE_DOCKER_IMAGE`); `docs/usage.md` has a recipe.

### Requirement: the Go pin is manual and surfaced as an operator reminder
**Reason**: Go is a project language runtime, not a tool the agent needs (`docs/vision-and-scope.md`); it leaves the base image (#219).
**Migration**: Install Go in a child image (`CLAUDE_DOCKER_IMAGE`); `docs/usage.md` has a recipe.

### Requirement: Go runtime code-fetch documented in the threat model
**Reason**: Go is a project language runtime, not a tool the agent needs (`docs/vision-and-scope.md`); it leaves the base image (#219).
**Migration**: Install Go in a child image (`CLAUDE_DOCKER_IMAGE`); `docs/usage.md` has a recipe.

### Requirement: Go environment exported by the image
**Reason**: Go is a project language runtime, not a tool the agent needs (`docs/vision-and-scope.md`); it leaves the base image (#219).
**Migration**: Install Go in a child image (`CLAUDE_DOCKER_IMAGE`); `docs/usage.md` has a recipe.

### Requirement: PATH ordering keeps volume-persisted directories non-shadowing
**Reason**: Go is a project language runtime, not a tool the agent needs (`docs/vision-and-scope.md`); it leaves the base image (#219).
**Migration**: Re-stated without Go in `package-managers`, as *PATH ordering keeps volume-persisted directories non-shadowing*.
