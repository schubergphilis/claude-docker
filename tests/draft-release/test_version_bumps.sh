#!/usr/bin/env bash
# Every way the version can move, from every kind of change that can move it.
#
# One published release stands as the baseline; the range holds the change under test. The
# assertion is the pair the action writes to its outputs: the version, and the bump it read.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

# bump_case <name> <previous tag> <want version> <want bump> <compare json> [<pr number> <pr json>]...
bump_case() {
  local name="$1" prev="$2" want_version="$3" want_bump="$4" compare="$5"; shift 5
  fresh_fixtures
  printf '[{"id":1,"tag_name":"%s","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]\n' "${prev}" > "${F}/releases.json"
  printf '%s\n' "${compare}" > "${F}/compare.json"
  while [[ $# -gt 0 ]]; do printf '%s\n' "$2" > "${F}/pull_$1.json"; shift 2; done

  run DRY_RUN=true
  local got want
  got="$(field version) ($(field bump))"
  want="${want_version} (${want_bump})"
  check "${name}" "${prev} -> ${want}" "${got}" "${want}"
}

# Builders for the compare fixture and a pull request.
range() { printf '{"commits": [%s]}' "$1"; }
commit() { printf '{"sha":"%s","parents":[{"sha":"%s"}],"commit":{"message":"%s"}}' "$1" "$2" "$3"; }
merge() { printf '{"sha":"%s","parents":[{"sha":"%s"},{"sha":"b0000000"}],"commit":{"message":"Merge pull request #%s from OWNER/topic"}}' "$1" "$2" "$3"; }
pr() { printf '{"title":"%s","user":{"login":"author-a"},"body":%s}' "$1" "${2:-\"\"}"; }

section "patch"
bump_case "fix only"                  v1.2.3 v1.2.4  patch "$(range "$(commit head0000 base0000 'fix: repair the thing')")"
bump_case "chore only"                v1.2.3 v1.2.4  patch "$(range "$(commit head0000 base0000 'chore(deps): bump a pin')")"
bump_case "docs, test and refactor"   v1.2.3 v1.2.4  patch "$(range "$(commit e1000000 base0000 'docs: a note'),$(commit e2000000 e1000000 'test: a case'),$(commit head0000 e2000000 'refactor: tidy up')")"
bump_case "non-conventional subject"  v1.2.3 v1.2.4  patch "$(range "$(commit head0000 base0000 'Just did a thing')")"
bump_case "patch resets nothing"      v0.0.9 v0.0.10 patch "$(range "$(commit head0000 base0000 'fix: repair the thing')")"

section "minor"
bump_case "feat only"                 v1.2.3  v1.3.0 minor "$(range "$(commit head0000 base0000 'feat: add the thing')")"
bump_case "feat with a scope"         v1.2.3  v1.3.0 minor "$(range "$(commit head0000 base0000 'feat(api): add the thing')")"
bump_case "feat wins over fix"        v1.2.3  v1.3.0 minor "$(range "$(commit e1000000 base0000 'fix: repair the thing'),$(commit head0000 e1000000 'feat: add the thing')")"
bump_case "minor resets the patch"    v2.4.17 v2.5.0 minor "$(range "$(commit head0000 base0000 'feat: add the thing')")"

section "major"
bump_case "! on feat"                    v1.2.3  v2.0.0 major "$(range "$(commit head0000 base0000 'feat!: change the interface')")"
bump_case "! on fix"                     v1.2.3  v2.0.0 major "$(range "$(commit head0000 base0000 'fix!: change the interface')")"
bump_case "! with a scope"               v1.2.3  v2.0.0 major "$(range "$(commit head0000 base0000 'chore(deps)!: drop node 18')")"
bump_case "major resets minor and patch" v2.4.17 v3.0.0 major "$(range "$(commit head0000 base0000 'feat!: change the interface')")"
bump_case "footer in a pull request"     v1.2.3  v2.0.0 major "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'refactor(core): drop the legacy client' '"Rework.\r\n\r\nBREAKING CHANGE: callers must pass a token."')"
bump_case "BREAKING-CHANGE spelling"     v1.2.3  v2.0.0 major "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'refactor(core): drop the legacy client' '"BREAKING-CHANGE: callers must pass a token."')"
bump_case "! in a pull request title"    v1.2.3  v2.0.0 major "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'feat(core)!: change the interface')"
bump_case "major beats feat and fix"     v1.2.3  v2.0.0 major "$(range "$(commit e1000000 base0000 'feat: add the thing'),$(commit e2000000 e1000000 'fix: repair the thing'),$(commit head0000 e2000000 'feat!: change the interface')")"

section "not a breaking change"
# The marker counts only as a footer: at the start of a line, with its colon, in upper case,
# and outside a fenced block. A pull request that writes about the marker is not declaring one.
bump_case "marker named mid-sentence" v1.2.3 v1.2.4 patch "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'fix(cli): quote the path' '"The docs mention a `BREAKING CHANGE:` footer here."')"
bump_case "marker inside a fence"     v1.2.3 v1.2.4 patch "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'fix(cli): quote the path' '"Example:\r\n\r\n```\r\nBREAKING CHANGE: not a real one\r\n```\r\n"')"
bump_case "lowercase breaking change" v1.2.3 v1.2.4 patch "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'fix(cli): quote the path' '"breaking change: lowercase is not the marker"')"
bump_case "marker without the colon"  v1.2.3 v1.2.4 patch "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'fix(cli): quote the path' '"BREAKING CHANGE was avoided in this one"')"

section "below 1.0.0 (pre_major, the default)"
bump_case "breaking moves the minor"    v0.3.4 v0.4.0  minor "$(range "$(commit head0000 base0000 'feat!: change the interface')")"
bump_case "breaking footer, same shift" v0.3.4 v0.4.0  minor "$(range "$(merge head0000 base0000 3001)")" \
  3001 "$(pr 'refactor(core): drop the legacy client' '"BREAKING CHANGE: callers must pass a token."')"
bump_case "feat moves the patch"        v0.3.4 v0.3.5  patch "$(range "$(commit head0000 base0000 'feat: add the thing')")"
bump_case "fix moves the patch"         v0.3.4 v0.3.5  patch "$(range "$(commit head0000 base0000 'fix: repair the thing')")"
bump_case "breaking off a 0.0.x"        v0.0.1 v0.1.0  minor "$(range "$(commit head0000 base0000 'feat!: change the interface')")"
bump_case "1.0.0 is never reached"      v0.9.9 v0.10.0 minor "$(range "$(commit head0000 base0000 'feat!: change the interface')")"
bump_case "no effect from 1.0.0 on"     v1.0.0 v2.0.0  major "$(range "$(commit head0000 base0000 'feat!: change the interface')")"

section "below 1.0.0 with pre_major: false"
PRE_MAJOR=false bump_case "breaking reaches 1.0.0" v0.3.4 v1.0.0 major "$(range "$(commit head0000 base0000 'feat!: change the interface')")"
PRE_MAJOR=false bump_case "feat still the minor"   v0.3.4 v0.4.0 minor "$(range "$(commit head0000 base0000 'feat: add the thing')")"
PRE_MAJOR=false bump_case "fix still the patch"    v0.3.4 v0.3.5 patch "$(range "$(commit head0000 base0000 'fix: repair the thing')")"

finish
