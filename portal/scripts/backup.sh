#!/usr/bin/env bash
# Trigger a manual fly.io Postgres snapshot for the prod cluster.
# fly's daily snapshot at 04:00 UTC retains for 7 days; this is for
# operator-initiated checkpoints (pre-deploy, pre-migration).
#
# Usage:
#   scripts/backup.sh                # snapshot emisar-prod-db
#   PG_APP=emisar-staging-db scripts/backup.sh

set -euo pipefail

PG_APP="${PG_APP:-emisar-prod-db}"

command -v fly >/dev/null || {
  echo "fly CLI not installed. brew install flyctl"
  exit 1
}

echo ">>> creating snapshot of ${PG_APP}"
fly pg backup create -a "${PG_APP}"

echo
echo ">>> snapshots:"
fly pg backup list -a "${PG_APP}"
