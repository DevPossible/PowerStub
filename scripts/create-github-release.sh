#!/bin/sh
# Called by the final GitLab job; retries verify the exact published tag.
set -eu
if [ "${CI_COMMIT_BRANCH:-}" != "main" ] || [ -n "${CI_COMMIT_TAG:-}" ]; then
    echo 'Releases require a main-branch pipeline, never a tag pipeline.' >&2
    exit 1
fi
if [ "${SHOULD_RELEASE:-}" != 'true' ]; then
    echo "No release needed for v${VERSION}."
    exit 0
fi
: "${GITHUB_PAT:?GITHUB_PAT is required}"
: "${GITHUB_REPO:?GITHUB_REPO is required}"
: "${VERSION:?VERSION is required}"
body="$(jq -Rs . < changelog.md)"
payload="$(jq -n --arg tag "v${VERSION}" --arg name "PowerStub v${VERSION}" \
    --argjson body "$body" '{tag_name: $tag, name: $name, body: $body, draft: false, prerelease: false}')"
status="$(curl -sS -o response.json -w '%{http_code}' -X POST \
    -H "Authorization: token ${GITHUB_PAT}" -H 'Accept: application/vnd.github.v3+json' \
    -H 'Content-Type: application/json' \
    "https://api.github.com/repos/${GITHUB_REPO}/releases" -d "$payload")"
if [ "$status" = '201' ]; then
    echo "Created GitHub release v${VERSION}."
elif [ "$status" = '422' ] && jq -e '.errors | any(.code == "already_exists" and .field == "tag_name")' response.json >/dev/null 2>&1; then
    # HTTP 422 also represents other validation failures. Never silently accept them.
    existing_status="$(curl -sS -o existing-release.json -w '%{http_code}' \
        -H "Authorization: token ${GITHUB_PAT}" -H 'Accept: application/vnd.github.v3+json' \
        "https://api.github.com/repos/${GITHUB_REPO}/releases/tags/v${VERSION}")"
    if [ "$existing_status" = '200' ] && jq -e --arg tag "v${VERSION}" \
        '.tag_name == $tag and .draft == false and .prerelease == false' existing-release.json >/dev/null; then
        echo "Verified existing published GitHub release v${VERSION}."
    else
        echo "Could not verify an existing published release v${VERSION}; HTTP ${existing_status}." >&2
        exit 1
    fi
else
    echo "Failed to create GitHub release. HTTP ${status}" >&2
    cat response.json >&2
    exit 1
fi
