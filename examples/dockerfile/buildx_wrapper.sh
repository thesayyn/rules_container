#!/usr/bin/env bash

set -o errexit -o nounset -o pipefail

$BUILDX \
  build - \
  --no-cache \
  --builder $BUILDER_NAME \
  --file $DOCKER_FILE \
  --platform $PLATFORM \
  --output=type=oci,tar=false,dest=$OUTPUT_DIR \
  < $BUILDX_CONTEXT
