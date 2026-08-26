#!/bin/bash

set -euo pipefail

tag="${1:?Usage: release-notes.sh <tag>}"
previous_tag="$(git describe --tags --abbrev=0 "${tag}^" 2>/dev/null || true)"

printf '## Changes\n\n'
if [[ -n "$previous_tag" ]]; then
    git log --no-merges --pretty='- %s' "$previous_tag..$tag"
else
    git log --no-merges --pretty='- %s' "$tag"
fi
