#!/usr/bin/env bash
#
# Build and run the emisar runner in Docker, pointing at a Phoenix
# control plane running on the host. Usage:
#
#   ./runner/docker/run.sh emkey-enroll-...
#
# The container talks to the host via `host.docker.internal:4000`
# (Docker Desktop on macOS/Windows provides this automatically; on
# Linux we pass `--add-host=host.docker.internal:host-gateway`).
#
# The first run mints a per-runner token via POST /runner/register and
# persists it in the named volume `emisar-runner-data`, so subsequent
# runs reuse it — same runner identity across restarts.

set -euo pipefail

ENROLLMENT_KEY="${1:-${EMISAR_ENROLLMENT_KEY:-}}"
EMISAR_URL="${EMISAR_URL:-http://host.docker.internal:4000}"
IMAGE="${IMAGE:-emisar/runner:dev}"

if [ -z "$ENROLLMENT_KEY" ]; then
  echo "usage: $0 <enrollment-key>"
  echo "       or:   EMISAR_ENROLLMENT_KEY=emkey-enroll-... $0"
  exit 1
fi

# repo root (this script lives at runner/docker/run.sh, so up two),
# regardless of where the script is invoked from. Used as the docker build
# context so the Dockerfile can COPY the sibling packs/ dir.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo ">>> building $IMAGE"
docker build \
  -f "$REPO_ROOT/runner/docker/Dockerfile" \
  -t "$IMAGE" \
  "$REPO_ROOT"

echo ">>> running $IMAGE"
exec docker run --rm -it \
  --name emisar-runner-dev \
  --add-host=host.docker.internal:host-gateway \
  -e EMISAR_ENROLLMENT_KEY="$ENROLLMENT_KEY" \
  -e EMISAR_URL="$EMISAR_URL" \
  -v emisar-runner-data:/var/lib/emisar \
  "$IMAGE"
