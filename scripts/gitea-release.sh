#!/bin/bash
#
#------------------------------------------------------------------------------
# Publishes a Gitea release for an existing tag and uploads its assets,
# replacing any release an earlier run left for the same tag. Tags with a
# "-" (such as 0.5.0-rc.1) are marked as pre-releases.
#
# Usage:
#  scripts/gitea-release.sh <repo-api-url> <token> <tag> <notes-file> <asset>...
#
#  <repo-api-url> is https://host/api/v1/repos/<owner>/<repo>
#------------------------------------------------------------------------------
#
set -euo pipefail

API="${1:?repo API URL required}"
TOKEN="${2:?token required}"
TAG="${3:?tag required}"
NOTES="${4:?notes file required}"
shift 4

AUTH="Authorization: token ${TOKEN}"

# Replace a release left by an earlier run of this tag.
EXISTING="$(curl -fsS -H "$AUTH" "${API}/releases/tags/${TAG}" 2>/dev/null \
    | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])' 2>/dev/null || true)"
if [[ -n "$EXISTING" ]]; then
    curl -fsS -X DELETE -H "$AUTH" "${API}/releases/${EXISTING}" >/dev/null
fi

BODY="$(/usr/bin/python3 -I -c '
import json, sys
tag, notes = sys.argv[1], open(sys.argv[2]).read()
print(json.dumps({"tag_name": tag, "name": tag, "body": notes,
                  "draft": False, "prerelease": "-" in tag}))
' "$TAG" "$NOTES")"

ID="$(curl -fsS -X POST -H "$AUTH" -H "Content-Type: application/json" \
    -d "$BODY" "${API}/releases" \
    | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin)["id"])')"

for asset in "$@"; do
    name="$(basename "$asset")"
    curl -fsS -X POST -H "$AUTH" -F "attachment=@${asset}" \
        "${API}/releases/${ID}/assets?name=${name}" >/dev/null
    echo "Uploaded ${name}"
done
echo "Published release ${TAG} (id ${ID})"
