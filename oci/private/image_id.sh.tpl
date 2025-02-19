#!/usr/bin/env bash
# Read the configuration json sha256 digest from the manifest.json file passed
# as the first positional argument. Output that sha256 to the
# file provided as the second positional argument.
set -o pipefail -o errexit -o nounset

readonly JQ="{{jq_path}}"

CONFIG_PATH=$("$JQ" -r '.[0].Config' "$1")
# CONFIG_PATH will be blobs/sha256/<digest>
SHA256_OF_CONFIG="${CONFIG_PATH#blobs/sha256/}"

if [[ "$SHA256_OF_CONFIG" == "$CONFIG_PATH" ]]; then
  echo "Error: Failed to extract SHA256 digest from CONFIG_PATH" >&2
  exit 1
fi

echo "$SHA256_OF_CONFIG" > "$2"