#!/bin/bash
#
#------------------------------------------------------------------------------
# Cuts a release the git flow way, in one step:
#
#   1. Branches release/<version> from develop, bumps the version in
#      Sources/PortsApp/PortsApp.swift, runs the tests, and commits.
#   2. Merges the release branch into main and tags it with an annotated
#      tag whose message holds the release notes (which the Release
#      workflow publishes).
#   3. Merges main back into develop and deletes the release branch.
#
# Nothing is pushed unless --push is given; then main, develop and the tag
# go to every remote, branches first, so the tag starts the Release workflow.
#
# Usage:
#  scripts/release.sh [options] <version>
#
# Options:
#  -n, --notes <file>  Release notes (Markdown). Defaults to a list of the
#                      commit subjects on develop since the last release.
#  --skip-tests        Don't run swift test on the release branch.
#  --push              Push main, develop and the tag to every remote.
#  --dry-run           Show the version, notes and steps, and change nothing.
#  -h, --help          Show this help.
#------------------------------------------------------------------------------
#
set -euo pipefail
cd "$(dirname "$0")/.."

usage() { sed -n '/^# Cuts a release/,/^#-----/p' "$0" | sed 's/^# \{0,1\}//; /^-----/d'; }
die() { echo "error: $*" >&2; exit 1; }

NOTES_FILE=""
SKIP_TESTS=false
PUSH=false
DRY_RUN=false
VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n | --notes) NOTES_FILE="${2:?--notes needs a file}"; shift 2 ;;
        --skip-tests) SKIP_TESTS=true; shift ;;
        --push) PUSH=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h | --help) usage; exit 0 ;;
        -*) die "unknown option $1 (see --help)" ;;
        *) [[ -z "$VERSION" ]] || die "only one version, please"; VERSION="$1"; shift ;;
    esac
done
[[ -n "$VERSION" ]] || { usage; exit 1; }
VERSION="${VERSION#v}"

SOURCE="Sources/PortsApp/PortsApp.swift"
BRANCH="release/${VERSION}"

# --- Checks: nothing is changed until all of these pass. ---------------------

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]] \
    || die "${VERSION} isn't a version like 1.2.3 or 1.2.3-rc.1"
[[ -z "$(git status --porcelain)" ]] || die "the working tree has uncommitted changes"
git rev-parse --verify --quiet "refs/tags/${VERSION}" >/dev/null && die "tag ${VERSION} already exists"
git rev-parse --verify --quiet "refs/heads/${BRANCH}" >/dev/null && die "branch ${BRANCH} already exists"
for branch in main develop; do
    git rev-parse --verify --quiet "refs/heads/${branch}" >/dev/null || die "there is no ${branch} branch"
done

CURRENT="$(git show "develop:${SOURCE}" | grep -m1 -o '?? "[^"]*"' | tr -d '?" ')"
[[ -n "$CURRENT" ]] || die "can't find the version in ${SOURCE}"
[[ "$CURRENT" != "$VERSION" ]] || die "develop is already at version ${VERSION}"

# The new version must come after the current one: a higher x.y.z, or the
# same x.y.z when the current version is its pre-release (1.2.3-rc.1 -> 1.2.3).
newer() {
    local new="${1%%-*}" old="${2%%-*}" a b i
    IFS=. read -ra a <<<"$new"
    IFS=. read -ra b <<<"$old"
    for i in 0 1 2; do
        ((10#${a[i]:-0} > 10#${b[i]:-0})) && return 0
        ((10#${a[i]:-0} < 10#${b[i]:-0})) && return 1
    done
    [[ "$2" == *-* && "$1" != *-* ]] || [[ "$2" == *-* && "$1" > "$2" ]]
}
newer "$VERSION" "$CURRENT" || die "${VERSION} doesn't come after the current version ${CURRENT}"

# Every remote's main and develop must already be in the local branches, so
# the merges below don't build on stale history.
for remote in $(git remote); do
    git fetch --quiet "$remote" || die "can't fetch ${remote}"
    for branch in main develop; do
        if git rev-parse --verify --quiet "refs/remotes/${remote}/${branch}" >/dev/null &&
            ! git merge-base --is-ancestor "${remote}/${branch}" "$branch"; then
            die "${remote}/${branch} has commits that local ${branch} doesn't; pull first"
        fi
    done
done

LAST_TAG="$(git describe --tags --abbrev=0 main 2>/dev/null || true)"
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
if [[ -n "$NOTES_FILE" ]]; then
    [[ -f "$NOTES_FILE" ]] || die "no notes file at ${NOTES_FILE}"
    cp "$NOTES_FILE" "$NOTES"
else
    git log --no-merges --format='- %s' ${LAST_TAG:+"${LAST_TAG}.."}develop \
        | grep -v '^- chore(release):' >"$NOTES" || true
fi
[[ -s "$NOTES" ]] || die "the release notes are empty"

echo "Release ${VERSION} (develop is at ${CURRENT}${LAST_TAG:+, last release ${LAST_TAG}})"
echo
echo "Notes:"
sed 's/^/  /' "$NOTES"
echo
if $DRY_RUN; then
    echo "Dry run; would:"
    echo "  - branch ${BRANCH} from develop and bump ${SOURCE} from ${CURRENT} to ${VERSION}"
    $SKIP_TESTS || echo "  - run swift test"
    echo "  - merge ${BRANCH} into main and tag it ${VERSION}"
    echo "  - merge main into develop and delete ${BRANCH}"
    $PUSH && echo "  - push main, develop and ${VERSION} to: $(git remote | tr '\n' ' ')"
    exit 0
fi

# --- The release. ------------------------------------------------------------

START="$(git symbolic-ref --quiet --short HEAD || git rev-parse HEAD)"
fail() {
    echo "error: stopped while ${STEP}; the repository is left as it is so you can finish or undo it" >&2
}
trap 'fail; rm -f "$NOTES"' ERR

STEP="creating ${BRANCH}"
git checkout --quiet -b "$BRANCH" develop
sed -i '' "s/?? \"${CURRENT//./\\.}\"/?? \"${VERSION}\"/g" "$SOURCE"
[[ "$(grep -c "?? \"${VERSION}\"" "$SOURCE")" -ge 1 ]] || { STEP="bumping the version"; false; }

if ! $SKIP_TESTS; then
    STEP="running the tests"
    swift test
fi

STEP="committing the version bump"
{ echo "chore(release): bump version to ${VERSION}"; echo; cat "$NOTES"; } \
    | git commit --quiet --all --file=-

STEP="merging ${BRANCH} into main"
git checkout --quiet main
git merge --quiet --no-ff "$BRANCH" -m "Merge branch '${BRANCH}'"
{ echo "Release ${VERSION}"; echo; cat "$NOTES"; } | git tag --annotate "$VERSION" --file=-

STEP="merging main back into develop"
git checkout --quiet develop
git merge --quiet --no-ff main -m "Merge branch 'main' into develop"
git branch --quiet -d "$BRANCH"

if $PUSH; then
    for remote in $(git remote); do
        STEP="pushing to ${remote}"
        git push --quiet "$remote" main develop
        git push --quiet "$remote" "refs/tags/${VERSION}"
    done
fi

[[ "$START" == "develop" ]] || git checkout --quiet "$START" 2>/dev/null || true

echo "Released ${VERSION}: main is tagged ${VERSION} and merged back into develop."
if $PUSH; then
    echo "Pushed to: $(git remote | tr '\n' ' ')"
else
    echo "To publish it:"
    for remote in $(git remote); do
        echo "  git push ${remote} main develop && git push ${remote} ${VERSION}"
    done
fi
