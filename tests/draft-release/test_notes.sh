#!/usr/bin/env bash
# What the notes look like, from a history with a bit of everything in it.
#
# The range has a merge commit, a squash merge, a commit pushed straight to the branch, a
# commit that is not a Conventional Commit at all, and a pull request whose title is written
# as shell. The commits inside the merged branch are in the range too, as they would be from
# the API, and must not be listed twice.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${HERE}/lib.sh"

MARKER='<!-- managed by claude-docker draft-release -->'

fresh_fixtures
printf '%s\n' '[{"id":1,"tag_name":"v3.3.0","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]' > "${F}/releases.json"
cat > "${F}/compare.json" <<'JSON'
{"commits": [
  {"sha":"c1000000","parents":[{"sha":"base0000"}],"commit":{"message":"Update stuff\n\nno convention here"}},
  {"sha":"c2000000","parents":[{"sha":"c1000000"}],"commit":{"message":"chore(deps)!: drop node 18"}},
  {"sha":"c3000000","parents":[{"sha":"c1000000"},{"sha":"c2000000"}],"commit":{"message":"Merge pull request #1001 from OWNER/refactor\n\nrefactor(core): drop the legacy client"}},
  {"sha":"c4000000","parents":[{"sha":"c3000000"}],"commit":{"message":"docs: tidy the readme"}},
  {"sha":"c5000000","parents":[{"sha":"c4000000"}],"commit":{"message":"fix(api): stop the leak (#1002)"}},
  {"sha":"b2000000","parents":[{"sha":"c5000000"}],"commit":{"message":"feat: add thing"}},
  {"sha":"head0000","parents":[{"sha":"c5000000"},{"sha":"b2000000"}],"commit":{"message":"Merge pull request #1003 from OWNER/feature\n\nfeat(release): draft releases from conventional commits"}}
]}
JSON
printf '%s\n' '{"title":"refactor(core): drop the legacy client","user":{"login":"author-a"},"body":"Rework.\r\n\r\nBREAKING CHANGE: callers must pass a token."}' > "${F}/pull_1001.json"
printf '%s\n' '{"title":"fix(api): stop the leak","user":{"login":"author-b"},"body":null}' > "${F}/pull_1002.json"
printf '%s\n' '{"title":"feat(x): $(touch /tmp/pwned) `id` ${IFS} & | ; done","user":{"login":"author-c"},"body":"Adds the drafter."}' > "${F}/pull_1003.json"
rm -f /tmp/pwned
run

section "the notes"
check "the range" "five entries: two merges, a squash, a push, an untyped commit" "$(field changes)" "5"
check "the range" "the commits inside the merged branch are not listed again" "$(count_notes 'add thing')" "0"
check "the version" "the footer in #1001 makes it a major" "$(field version) ($(field bump))" "v4.0.0 (major)"

check "headings" "breaking changes come first and alone" "$(notes | grep -n '^## ' | head -1)" "1:## Breaking changes"
check "headings" "in the configured order, empty sections left out" \
  "$(notes | grep '^## ' | tr '\n' '|')" "## Breaking changes|## Features|## Fixes|## Documentation|## Other changes|"

check "entries" "a pull request is its title, number and author" "$(count_notes '^\* fix(api): stop the leak (#1002) @author-b$')" "1"
check "entries" "a pushed commit is its subject and short sha" "$(count_notes '^\* docs: tidy the readme (c4000000)$')" "1"
check "entries" "an untyped subject lands under the other heading" "$(notes | grep -A2 '^## Other changes' | grep -c 'Update stuff (c1000000)')" "1"
check "entries" "a breaking entry is under its own heading, not its type" "$(notes | grep -A2 '^## Breaking changes' | grep -c 'drop the legacy client (#1001) @author-a')" "1"

check "trailer" "the compare link runs from the baseline to the new version" "$(count_notes 'compare/v3.3.0\.\.\.v4.0.0')" "1"
check "trailer" "the marker is the last line" "$(notes | tail -1)" "${MARKER}"

section "author-controlled text"
check "a title written as shell" "is rendered literally" "$(count_notes 'feat(x): \$(touch /tmp/pwned) `id` \${IFS} & | ; done (#1003) @author-c')" "1"
check "a title written as shell" "and never executed" "$([[ -e /tmp/pwned ]] && echo executed || echo not-executed)" "not-executed"

# --- a stack merged from the top -----------------------------------------------------------
# #2002 was merged into #2001's branch, then #2001 into main. On main's first-parent line there is
# one merge commit, #2001; #2002's is inside it. #2002 shipped all the same, and it is a feat, so
# the version has to move a minor -- listing only #2001 would ship a feature under a patch.
# A second stacked pull request, #2003, was squash-merged into the branch, so it is a "(#2003)"
# subject rather than a merge commit. The branch also holds a commit that names an issue the
# same way; the two are told apart by whether the pull request can be read.
fresh_fixtures
printf '%s\n' '[{"id":1,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]' > "${F}/releases.json"
cat > "${F}/compare.json" <<'JSON'
{"commits": [
  {"sha":"a1000000","parents":[{"sha":"base0000"}],"commit":{"message":"test: add the suite"}},
  {"sha":"a2000000","parents":[{"sha":"a1000000"}],"commit":{"message":"chore: fix a typo (#2099)"}},
  {"sha":"b1000000","parents":[{"sha":"a2000000"}],"commit":{"message":"feat: add the endpoint"}},
  {"sha":"a3000000","parents":[{"sha":"a2000000"},{"sha":"b1000000"}],"commit":{"message":"Merge pull request #2002 from OWNER/feature\n\nfeat(api): add the endpoint"}},
  {"sha":"a4000000","parents":[{"sha":"a3000000"}],"commit":{"message":"docs(api): describe the endpoint (#2003)"}},
  {"sha":"head0000","parents":[{"sha":"base0000"},{"sha":"a4000000"}],"commit":{"message":"Merge pull request #2001 from OWNER/tooling\n\ntest(tooling): add the suite"}}
]}
JSON
printf '%s\n' '{"title":"test(tooling): add the suite","user":{"login":"author-a"},"body":""}' > "${F}/pull_2001.json"
printf '%s\n' '{"title":"feat(api): add the endpoint","user":{"login":"author-a"},"body":""}' > "${F}/pull_2002.json"
printf '%s\n' '{"title":"docs(api): describe the endpoint","user":{"login":"author-b"},"body":""}' > "${F}/pull_2003.json"
run

section "a stack merged from the top"
check "the nested pull request" "is listed" "$(count_notes '^\* feat(api): add the endpoint (#2002) @author-a$')" "1"
check "the nested pull request" "once" "$(count_notes '#2002')" "1"
check "the outer pull request" "is listed too" "$(count_notes '(#2001) @author-a')" "1"
check "a squash-merged stacked pull request" "is listed once, by its pull request" "$(count_notes '^\* docs(api): describe the endpoint (#2003) @author-b$')" "1"
check "the version" "moves a minor for the feat that shipped inside" "$(field version) ($(field bump))" "v1.1.0 (minor)"
check "the branch's own commits" "are not listed" "$(count_notes 'add the suite (a1000000)\|add the endpoint (b1000000)')" "0"
check "an issue reference inside the branch" "is not an entry" "$(count_notes 'fix a typo')" "0"
check "an issue reference inside the branch" "and raises no warning" "$(count_warning 'Pull request #2099 could not be read')" "0"
check "the range" "three entries, for the three pull requests" "$(field changes)" "3"

# --- one pull request, two commits ---------------------------------------------------------
# A squash-merged pull request's commit sits on main; a copy of it -- a cherry-pick, subject
# and "(#N)" intact -- sits inside a branch merged later. Both are in the range under
# different shas, so the pull request is met twice and must be listed once. This is the only
# way one number reaches the loop twice, and therefore the only thing that exercises the
# dedupe. The branch's own line also carries a "(#N)" whose pull request cannot be read: on
# the branch's own line that is a warning and the subject, not a silent skip.
fresh_fixtures
printf '%s\n' '[{"id":1,"tag_name":"v1.0.0","draft":false,"prerelease":false,"body":"x","html_url":"u1"}]' > "${F}/releases.json"
cat > "${F}/compare.json" <<'JSON'
{"commits": [
  {"sha":"c1000000","parents":[{"sha":"base0000"}],"commit":{"message":"feat(api): add the endpoint (#2101)"}},
  {"sha":"d1000000","parents":[{"sha":"c1000000"}],"commit":{"message":"feat(api): add the endpoint (#2101)"}},
  {"sha":"c2000000","parents":[{"sha":"c1000000"},{"sha":"d1000000"}],"commit":{"message":"Merge pull request #2102 from OWNER/backport\n\nchore(release): backport the endpoint"}},
  {"sha":"head0000","parents":[{"sha":"c2000000"}],"commit":{"message":"chore(deps): bump a pin (#2199)"}}
]}
JSON
printf '%s\n' '{"title":"feat(api): add the endpoint","user":{"login":"author-a"},"body":""}' > "${F}/pull_2101.json"
printf '%s\n' '{"title":"chore(release): backport the endpoint","user":{"login":"author-b"},"body":""}' > "${F}/pull_2102.json"
run

section "one pull request, two commits"
check "a pull request met twice" "is listed once" "$(count_notes '#2101')" "1"
check "a pull request met twice" "and the merge that carried the copy is listed too" "$(count_notes '(#2102) @author-b')" "1"
check "an unreadable (#N) on the branch's own line" "warns" "$(count_warning 'Pull request #2199 could not be read')" "1"
check "an unreadable (#N) on the branch's own line" "and falls back to the subject" "$(count_notes '^\* chore(deps): bump a pin (#2199) (head0000)$')" "1"
check "the range" "three entries" "$(field changes)" "3"
# Newest first is a named property of the notes, so it is asserted, not assumed: the chore at
# the head of the range comes before the backport merge below it.
check "entries within a section" "newest first" \
  "$(notes | grep -A3 '^## Maintenance' | grep -oE '#(2102|2199)' | tr '\n' ' ')" "#2199 #2102 "

finish
