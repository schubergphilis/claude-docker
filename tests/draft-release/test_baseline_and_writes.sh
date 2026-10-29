#!/usr/bin/env bash
# Which release becomes the baseline, and which release a write is allowed to touch.
#
# Every case here is a way the action once went wrong in a consumer, or a way it could:
# a repository whose every release is a prerelease, two drafts carrying one tag, a draft
# with no tag yet, a tag with a leading zero. Each is asserted against the outputs, the
# recorded writes, or the log -- never eyeballed.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

MARKER='<!-- managed by claude-docker draft-release -->'

# A two-commit range with a feat at the head, so every case has something to draft.
COMPARE='{"commits": [
  {"sha":"d1000000","parents":[{"sha":"base0000"}],"commit":{"message":"fix: repair the thing"}},
  {"sha":"head0000","parents":[{"sha":"d1000000"}],"commit":{"message":"feat: add the thing"}}
]}'
# The same two commits as the first-release path lists them: newest first, no parent at the root.
COMMITS='[{"sha":"head0000","parents":[{"sha":"d1000000"}],"commit":{"message":"feat: add the thing"}},
  {"sha":"d1000000","parents":[],"commit":{"message":"fix: repair the thing"}}]'

# setup <releases json>: a fresh fixture directory with these releases and the range above.
setup() {
  fresh_fixtures
  printf '%s\n' "$1" > "${F}/releases.json"
  printf '%s\n' "${COMPARE}" > "${F}/compare.json"
  printf '%s\n' "${COMMITS}" > "${F}/commits.json"
}

section "the baseline"

# Every published release is a prerelease. This is the shape that started it all.
setup '[{"id":11,"tag_name":"v0.1.1","draft":false,"prerelease":true,"body":"hand written","html_url":"u11"},
        {"id":10,"tag_name":"v0.1.0","draft":false,"prerelease":true,"body":"hand written","html_url":"u10"}]'
run
check "prereleases only" "baseline is v0.1.1, not the first version" "$(field previous_tag)" "v0.1.1"
check "prereleases only" "drafts v0.1.2, not v0.1.0" "$(field version)" "v0.1.2"

setup '[{"id":1,"tag_name":"v0.9.0","draft":false,"prerelease":false,"body":"x","html_url":"u1"},
        {"id":2,"tag_name":"v0.10.0","draft":false,"prerelease":false,"body":"x","html_url":"u2"},
        {"id":3,"tag_name":"v0.2.0","draft":false,"prerelease":false,"body":"x","html_url":"u3"}]'
run
check "unordered tags" "highest version wins, not the newest id" "$(field previous_tag)" "v0.10.0"

setup '[{"id":1,"tag_name":"v1.2.0-rc.1","draft":false,"prerelease":true,"body":"x","html_url":"u1"},
        {"id":2,"tag_name":"v1.2.0","draft":false,"prerelease":false,"body":"x","html_url":"u2"}]'
run
check "same triple" "the plain release outranks its prerelease" "$(field previous_tag)" "v1.2.0"

setup '[{"id":1,"tag_name":"v2.0.0","draft":true,"prerelease":false,"body":"a draft '"${MARKER}"'","html_url":"u1"},
        {"id":2,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u2"}]'
run
check "a draft exists" "a draft never becomes its own baseline" "$(field previous_tag)" "v1.0.0"

setup '[]'
run
check "no releases" "falls back to first_version" "$(field version)" "v0.1.0"
check "no releases" "and says nothing about a missing baseline" "$(count_warning 'No release to count from')" "0"

setup '[{"id":1,"tag_name":"release-2024","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]'
run
check "unparseable tags only" "warns instead of silently resetting" "$(count_warning 'No release to count from')" "1"
check "unparseable tags only" "and still drafts the first version" "$(field version)" "v0.1.0"

# A failed listing must never read as "this repository has no releases".
fresh_fixtures
printf '%s\n' "${COMPARE}" > "${F}/compare.json"
run
check "listing fails" "the run stops" "$(rc)" "1"
check "listing fails" "with no write attempted" "$(writes)" "0"
check "listing fails" "and says why" "$(count_error 'Cannot list the releases')" "1"

# A draft made in the UI carries no tag. An empty field once shifted every field after it
# one place left, which counted that draft as an unparseable published release.
setup '[{"id":20,"tag_name":"","draft":true,"prerelease":false,"body":"a UI draft","html_url":"u20"},
        {"id":21,"tag_name":"v1.4.0","draft":false,"prerelease":false,"body":"x","html_url":"u21"}]'
run
check "a draft with no tag" "does not shift the fields into a published release" "$(count_warning 'No release to count from')" "0"
check "a draft with no tag" "and the baseline is still the real release" "$(field previous_tag)" "v1.4.0"

# The documented consequence of counting prereleases: a beta ahead of the last full release
# is the baseline. Locked here so it stays a decision rather than becoming a surprise.
setup '[{"id":30,"tag_name":"v2.0.0-beta.1","draft":false,"prerelease":true,"body":"x","html_url":"u30"},
        {"id":31,"tag_name":"v1.4.0","draft":false,"prerelease":false,"body":"x","html_url":"u31"}]'
run
check "a beta ahead of a release" "the beta is the baseline" "$(field previous_tag)" "v2.0.0-beta.1"
check "a beta ahead of a release" "and the run says it is a prerelease" "$(count_log 'a prerelease\.')" "1"
# The trap at its sharpest: the beta counts by its triple, so a feature drafts v2.1.0 and
# v2.0.0 -- the release the beta was for -- is never finalised by the drafter.
check "a beta ahead of a release" "counted by its triple: v2.0.0 is skipped, not finalised" "$(field version)" "v2.1.0"

# Bash reads a leading-zero numeral as octal: v1.08.0 once aborted the run outright, and
# v1.010.0 quietly ranked as 8, which could hand the baseline to the wrong release.
setup '[{"id":1300,"tag_name":"v1.08.0","draft":false,"prerelease":false,"body":"x","html_url":"u1300"},
        {"id":1301,"tag_name":"v1.2.0","draft":false,"prerelease":false,"body":"x","html_url":"u1301"}]'
run
check "a leading-zero component" "does not abort the run" "$(rc)" "0"
check "a leading-zero component" "and counts as 8, so it wins over 1.2.0" "$(field previous_tag)" "v1.08.0"

setup '[{"id":1400,"tag_name":"v1.010.0","draft":false,"prerelease":false,"body":"x","html_url":"u1400"},
        {"id":1401,"tag_name":"v1.9.0","draft":false,"prerelease":false,"body":"x","html_url":"u1401"}]'
run
check "an octal-looking component" "counts as 10, not 8, so it wins over 1.9.0" "$(field previous_tag)" "v1.010.0"

section "what the draft describes"

# The incident: two merges seconds apart, events delivered out of order, and the run for the
# older commit survived. Drafting the branch rather than the waking commit makes that run
# harmless -- it resolves the branch to its tip and draws the same draft the other would have.
setup '[{"id":1,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]'
printf '%s\n' '{"sha":"head0000"}' > "${F}/commit_main.json"
run HEAD_SHA=main
check "head is a branch" "resolves to the tip and drafts from it" "$(field version)" "v1.1.0"
check "head is a branch" "and says which commit that was" "$(count_log 'Drafting main at head0000')" "1"

setup '[{"id":1,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]'
printf '%s\n' '{"sha":"head0000"}' > "${F}/commit_abc1234.json"
run HEAD_SHA=abc1234
check "head is an abbreviated sha" "resolves to the full sha, so the walk finds it" "$(field changes)" "2"

setup '[{"id":1,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]'
run HEAD_SHA=no-such-branch
check "head cannot be resolved" "the run stops" "$(rc)" "1"
check "head cannot be resolved" "before anything is written" "$(writes)" "0"
check "head cannot be resolved" "and names the call" "$(count_error 'Cannot resolve the head')" "1"

section "which release a write may touch"

setup '[{"id":500,"tag_name":"v1.0.1","draft":true,"prerelease":false,"body":"notes '"${MARKER}"'","html_url":"u500"},
        {"id":400,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u400"}]'
run
check "one managed draft" "updated by id, not by tag" \
  "$(grep -oE 'PATCH repos/[^ ]*releases/[0-9]+' "${F}/calls.log")" "PATCH repos/OWNER/REPO/releases/500"
check "one managed draft" "gh release is never used" "$(grep -c FORBIDDEN "${F}/calls.log")" "0"

# Two managed drafts carrying the same tag: the state a consumer was found in.
setup '[{"id":600,"tag_name":"v0.1.0","draft":true,"prerelease":true,"body":"live '"${MARKER}"'","html_url":"u600"},
        {"id":601,"tag_name":"v0.1.0","draft":true,"prerelease":false,"body":"stale '"${MARKER}"'","html_url":"u601"}]'
run
check "two managed drafts" "the run stops rather than pick one" "$(rc)" "1"
check "two managed drafts" "nothing is written" "$(writes)" "0"
check "two managed drafts" "both are named so a human can decide" "$(grep -oE 'u600 u601' "${F}/out.txt")" "u600 u601"

# The hazard behind an un-publish: a published release carrying the draft's tag. Written by
# tag, the draft flag on the write would have turned that release back into a draft.
setup '[{"id":700,"tag_name":"v1.1.0","draft":false,"prerelease":false,"body":"published, same tag","html_url":"u700"},
        {"id":701,"tag_name":"v1.1.0","draft":true,"prerelease":false,"body":"draft '"${MARKER}"'","html_url":"u701"}]'
run
check "tag shared with a release" "the draft is written, the release is not" \
  "$(grep -oE 'releases/70[01]' "${F}/calls.log")" "releases/701"

setup '[{"id":800,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u800"}]'
run PRERELEASE=true
check "prerelease: true" "the flag is written on the draft" "$(grep -oE 'prerelease=true' "${F}/calls.log")" "prerelease=true"

setup '[{"id":900,"tag_name":"v1.0.0","draft":true,"prerelease":true,"body":"was published once '"${MARKER}"'","html_url":"u900"}]'
run
check "stale flag on a draft" "cleared, not inherited" "$(grep -oE 'prerelease=false' "${F}/calls.log")" "prerelease=false"

# The write is the only call that changes anything. Its failure has to read like every
# other failure in the script, not like raw gh output.
setup '[{"id":1100,"tag_name":"v1.0.0","draft":true,"prerelease":false,"body":"draft '"${MARKER}"'","html_url":"u1100"}]'
echo "Not Found (HTTP 404)" > "${F}/write_fail"
run
check "a write that fails" "the run stops" "$(rc)" "1"
check "a write that fails" "with an annotation naming the call" "$(count_error 'Cannot PATCH the draft release')" "1"
check "a write that fails" "and the reason gh gave" "$(count_log 'Not Found (HTTP 404)')" "1"

# The prerelease input becomes a JSON boolean, so only two spellings are accepted.
setup '[{"id":1200,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u1200"}]'
run PRERELEASE=yes
check "prerelease: yes" "is refused before anything is written" "$(writes)" "0"
check "prerelease: yes" "and says what it wanted" "$(count_error 'prerelease must be true or false')" "1"

setup '[{"id":1000,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u1000"}]'
run DRY_RUN=true
check "dry run" "nothing is written" "$(writes)" "0"

finish
