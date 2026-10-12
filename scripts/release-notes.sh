#!/bin/bash
#
#------------------------------------------------------------------------------
# Checks that a release tag matches the app's version, then prints the
# release notes from the annotated tag's message (the body after the
# subject line, or the subject when there is no body).
#
# Usage:
#  scripts/release-notes.sh <tag>
#------------------------------------------------------------------------------
#
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:?usage: scripts/release-notes.sh <tag>}"
VERSION="${TAG#v}"

# The fallback version in PortsApp.swift is what `swift run` shows, so a
# release whose tag disagrees with it was cut without the version bump.
if ! grep -q "?? \"${VERSION}\"" Sources/PortsApp/PortsApp.swift; then
    echo "error: tag ${TAG} doesn't match the version in Sources/PortsApp/PortsApp.swift" >&2
    exit 1
fi

# CI checkouts may hold the tag as a plain ref to the commit; fetch the tag
# object itself so its message is available.
git fetch --quiet --force origin "refs/tags/${TAG}:refs/tags/${TAG}" 2>/dev/null || true

if [[ "$(git cat-file -t "refs/tags/${TAG}")" != "tag" ]]; then
    echo "Release ${VERSION}"
    exit 0
fi
BODY="$(git for-each-ref "refs/tags/${TAG}" --format='%(contents:body)')"
if [[ -n "${BODY//[[:space:]]/}" ]]; then
    printf '%s\n' "$BODY"
else
    git for-each-ref "refs/tags/${TAG}" --format='%(contents:subject)'
fi
