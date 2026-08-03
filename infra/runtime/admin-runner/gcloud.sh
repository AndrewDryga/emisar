#!/bin/bash
set -euo pipefail

# COS deliberately has no package manager. Keep the provider CLI isolated from
# the serving host: no mounts, no writable root, and authentication only through
# the VM service account exposed by the metadata server.
exec docker run --rm \
  --network host \
  --read-only \
  --cap-drop=ALL \
  --security-opt=no-new-privileges \
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=64m \
  --env CLOUDSDK_CONFIG=/tmp/gcloud \
  --env CLOUDSDK_CORE_DISABLE_USAGE_REPORTING=true \
  --env CLOUDSDK_COMPONENT_MANAGER_DISABLE_UPDATE_CHECK=true \
  "${gcloud_image}" \
  gcloud "$@"
