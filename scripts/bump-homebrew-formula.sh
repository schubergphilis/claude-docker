#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 Schuberg Philis
#
# Move Formula/claude-docker.rb to a stable release, run from the repo root by
# homebrew.yml once the tag is checked as vX.Y.Z and its image as published.
# Rewrites the formula's url and sha256 to the tag's source archive and prints
# the version the formula named before. Prints nothing and leaves the formula
# as is when it already names this tag or a newer one, so a dispatch for an
# old tag never moves it backwards.
#
# Usage: scripts/bump-homebrew-formula.sh <tag>
# Reads GITHUB_SERVER_URL and GITHUB_REPOSITORY, as a runner sets them.

set -euo pipefail

tag=$1
version="${tag#v}"
formula=Formula/claude-docker.rb
summary="${GITHUB_STEP_SUMMARY:-/dev/stderr}"

current="$(sed -nE 's|^  url ".*/refs/tags/v([0-9.]+)\.tar\.gz"$|\1|p' "${formula}")"
if [[ -z "${current}" ]]; then
  echo "::error title=Formula not recognised::No release url found in ${formula}." >&2
  exit 1
fi
if [[ "$(printf '%s\n' "${current}" "${version}" | sort -V | tail -n1)" != "${version}" ]]; then
  echo "The formula is at ${current}, newer than ${version}; leaving it." >> "${summary}"
  exit 0
fi
if [[ "${current}" == "${version}" ]]; then
  echo "The formula is already at ${version}." >> "${summary}"
  exit 0
fi

url="${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/archive/refs/tags/${tag}.tar.gz"
sha="$(curl -fsSL "${url}" | sha256sum | cut -d' ' -f1)"
# Written to a new file rather than with `sed -i`, whose syntax differs
# between GNU and BSD sed, so the tests also run on macOS.
sed -E \
  -e "s|^  url \".*\"$|  url \"${url}\"|" \
  -e "s|^  sha256 \"[0-9a-f]{64}\"$|  sha256 \"${sha}\"|" \
  "${formula}" > "${formula}.new"
mv "${formula}.new" "${formula}"
grep -qxF "  url \"${url}\"" "${formula}"
grep -qxF "  sha256 \"${sha}\"" "${formula}"

echo "${current}"
