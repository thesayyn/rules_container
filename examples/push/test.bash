#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly CRANE="${1/external\//../}"
readonly PUSH_IMAGE="$2"
readonly PUSH_IMAGE_INDEX="$3"
readonly PUSH_IMAGE_REPOSITORY_FILE="$4"
readonly PUSH_IMAGE_WO_TAGS="$5"

# start a registry
output=$(mktemp)
$CRANE registry serve --address=localhost:0 >> "$output" 2>&1 &
timeout=$((SECONDS+10))
while [ "${SECONDS}" -lt "${timeout}" ]; do
    port="$(sed -nr 's/.+serving on port ([0-9]+)/\1/p' < "$output")"
    [ -n "${port}" ] && break
done
REGISTRY="localhost:$port"

# should push image with default tags
REPOSITORY="${REGISTRY}/local" 
"${PUSH_IMAGE}" --repository "${REPOSITORY}"
"${CRANE}" digest "$REPOSITORY:latest"

# should push image_index with default tags
REPOSITORY="${REGISTRY}/local-index" 
"${PUSH_IMAGE_INDEX}" --repository "${REPOSITORY}"
"${CRANE}" digest "$REPOSITORY:nightly"


# should push image without default tags
REPOSITORY="${REGISTRY}/local-wo-tags" 
"${PUSH_IMAGE_WO_TAGS}" --repository "${REPOSITORY}"
TAGS=$("${CRANE}" ls "$REPOSITORY")
if [ -n "${TAGS}" ]; then 
    echo "image is not supposed to have any tags but got"
    echo "${TAGS}"
    exit 1
fi


# should push image to the repository defined in the file
set -ex
REPOSITORY="${REGISTRY}/repository-file"
"${PUSH_IMAGE_REPOSITORY_FILE}" --repository "${REPOSITORY}"
"${CRANE}" digest "$REPOSITORY:latest"


# should push image with the --tag flag.
REPOSITORY="${REGISTRY}/local-flag-tag" 
"${PUSH_IMAGE_WO_TAGS}" --repository "${REPOSITORY}" --tag "custom"
TAGS=$("${CRANE}" ls "$REPOSITORY")
if [ "${TAGS}" != "custom" ]; then 
    echo "image is supposed to have custom tag but got"
    echo "${TAGS}"
    exit 1
fi

# should fail since retry_count reached, since there is no repo
REPOSITORY="non-existing-repository"
if timeout 3 "${PUSH_IMAGE}" --repository "${REPOSITORY}" --retry_count 1; then
    echo "push didn't return in 3 seconds, potentially stuck?"
    exit 1
fi
