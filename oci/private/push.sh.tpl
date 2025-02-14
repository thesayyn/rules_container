#!/usr/bin/env bash
set -o pipefail -o errexit -o nounset

readonly CRANE="{{crane_path}}"
readonly JQ="{{jq_path}}"
readonly IMAGE_DIR="{{image_dir}}"
readonly TAGS_FILE="{{tags}}"
readonly FIXED_ARGS=({{fixed_args}})
readonly REPOSITORY_FILE="{{repository_file}}"
readonly RETRY_COUNT="{{retry_count}}"

function retry {
  local retries=$1
  shift

  local count=0
  until "$@"; do
    exit=$?
    count=$(($count + 1))
    if [ $count -ge $retries ]; then
      return $exit
    fi
  done
  return 0
}

REPOSITORY=""
if [ -f $REPOSITORY_FILE ] ; then
  REPOSITORY=$(tr -d '\n' < "$REPOSITORY_FILE")
fi

# set $@ to be FIXED_ARGS+$@
ALL_ARGS=(${FIXED_ARGS[@]+"${FIXED_ARGS[@]}"} $@)
if [[ ${#ALL_ARGS[@]} -gt 0 ]]; then
  set -- ${ALL_ARGS[@]}
fi

TAGS=()

# global crane flags to be passed with every crane invocation
GLOBAL_FLAGS=()

# this will hold args specific to `crane push``
ARGS=()

while (( $# > 0 )); do
  case $1 in
    (--allow-nondistributable-artifacts|--insecure|-v|--verbose)
      GLOBAL_FLAGS+=( "$1" )
      shift;;
    (--platform)
      GLOBAL_FLAGS+=( "--platform" "$2" )
      shift
      shift;;
    (-t|--tag)
      TAGS+=( "$2" )
      shift
      shift;;
    (--tag=*) 
      TAGS+=( "${1#--tag=}" )
      shift;;
    (-r|--repository)
      REPOSITORY="$2"
      shift
      shift;;
    (--repository=*)
      REPOSITORY="${1#--repository=}"
      shift;;
    (*) 
      ARGS+=( "$1" )
      shift;;
  esac
done

DIGEST=$("${JQ}" -r '.manifests[0].digest' "${IMAGE_DIR}/index.json")

REFS=$(mktemp)

retry RETRY_COUNT "${CRANE}" push "${GLOBAL_FLAGS[@]+"${GLOBAL_FLAGS[@]}"}" "${IMAGE_DIR}" "${REPOSITORY}@${DIGEST}" "${ARGS[@]+"${ARGS[@]}"}" --image-refs "${REFS}"


for tag in "${TAGS[@]+"${TAGS[@]}"}"
do
  retry RETRY_COUNT "${CRANE}" tag "${GLOBAL_FLAGS[@]+"${GLOBAL_FLAGS[@]}"}" $(cat "${REFS}") "${tag}"
done

if [[ -e "${TAGS_FILE:-}" ]]; then
  retry RETRY_COUNT cat "${TAGS_FILE}" | xargs -r -n1 "${CRANE}" tag "${GLOBAL_FLAGS[@]+"${GLOBAL_FLAGS[@]}"}" $(cat "${REFS}")
fi
