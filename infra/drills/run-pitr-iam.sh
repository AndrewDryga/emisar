#!/usr/bin/env bash
set -euo pipefail

project=${PROJECT_ID:-emisar}
source_instance=${SOURCE_INSTANCE:-emisar}
zone=${DRILL_ZONE:-us-central1-f}
apply=false

if [[ ${1:-} == --apply ]]; then
  apply=true
elif [[ $# -ne 0 ]]; then
  echo "usage: $0 [--apply]" >&2
  exit 2
fi

stamp=$(date -u +%y%m%d%H%M)
prefix="edrill-${stamp}-$(openssl rand -hex 3)"
clone="${prefix}-db"
service_account="${prefix}@${project}.iam.gserviceaccount.com"
vm="${prefix}-probe"
tmp=$(mktemp -d)
manifest_dir=${DRILL_MANIFEST_DIR:-"$(dirname "$0")/../.agent/drills"}
manifest="${manifest_dir}/${prefix}.env"

# shellcheck disable=SC2329 # invoked by the EXIT/INT/TERM trap below
cleanup() {
  rc=$?
  trap - EXIT INT TERM
  cleanup_rc=0
  if [[ $apply == true ]]; then
    PROJECT_ID="$project" "$(dirname "$0")/cleanup-recovery-drills.sh" --apply "$prefix" || cleanup_rc=$?
    if [[ $cleanup_rc -eq 0 ]]; then
      printf 'cleanup_verified_at=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >>"$manifest"
    fi
  fi
  rm -rf "$tmp"
  if [[ $rc -eq 0 && $cleanup_rc -ne 0 ]]; then
    echo "drill succeeded but cleanup failed; run cleanup-recovery-drills.sh --apply ${prefix}" >&2
    exit "$cleanup_rc"
  fi
  exit "$rc"
}
trap cleanup EXIT INT TERM

if date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  restore_time=$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)
  expires=$(date -u -d '12 hours' +%Y%m%d%H%M%S)
else
  restore_time=$(date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)
  expires=$(date -u -v+12H +%Y%m%d%H%M%S)
fi

cat >"$tmp/condition.json" <<EOF
{
  "title": "${prefix}-only",
  "description": "Temporary non-production recovery drill",
  "expression": "resource.name == 'projects/${project}/instances/${clone}' && resource.type == 'sqladmin.googleapis.com/Instance'"
}
EOF

echo "scratch clone: ${clone} at ${restore_time}"
echo "scratch probe: ${vm} in ${zone}"
if [[ $apply != true ]]; then
  echo "dry run only; production is read-only and all scratch resources are trap-cleaned with --apply"
  echo "with --apply the manifest also records measured_rto_seconds: elapsed from drill start to the restored clone serving an emisar_owner query"
  trap - EXIT INT TERM
  rm -rf "$tmp"
  exit 0
fi

# The RTO clock starts with the first recovery action so each exercise measures
# the restore leg (IAM setup, PITR clone, connect, validation query) against the
# committed 2-hour objective; application cutover is budgeted separately.
drill_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
drill_start_epoch=$(date +%s)

install -d -m 0700 "$manifest_dir"
umask 077
{
  printf 'drill_id=%q\n' "$prefix"
  printf 'project=%q\n' "$project"
  printf 'clone=%q\n' "$clone"
  printf 'probe_vm=%q\n' "$vm"
  printf 'service_account=%q\n' "$service_account"
  printf 'restore_time=%q\n' "$restore_time"
  printf 'drill_started_at=%q\n' "$drill_started_at"
  printf 'expires=%q\n' "$expires"
} >"$manifest"

gcloud iam service-accounts create "$prefix" --project "$project" \
  --display-name="Temporary recovery drill ${prefix}"
for role in roles/cloudsql.client roles/cloudsql.instanceUser; do
  gcloud projects add-iam-policy-binding "$project" \
    --member="serviceAccount:${service_account}" \
    --role="$role" \
    --condition-from-file="$tmp/condition.json" \
    --quiet
done

gcloud sql instances clone "$source_instance" "$clone" \
  --project "$project" \
  --point-in-time "$restore_time" \
  --preferred-zone "$zone" \
  --quiet
gcloud sql instances patch "$clone" --project "$project" \
  --update-labels="purpose=recovery-drill,drill_id=${prefix},expires=${expires}" \
  --no-deletion-protection \
  --quiet

gcloud sql users create "${prefix}@${project}.iam" \
  --project "$project" \
  --instance "$clone" \
  --type=CLOUD_IAM_SERVICE_ACCOUNT \
  --database-roles=emisar_owner

connection_name=$(gcloud sql instances describe "$clone" --project "$project" \
  --format='value(connectionName)')
cat >"$tmp/startup.sh" <<EOF
#!/bin/bash
set -euo pipefail
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl postgresql-client
curl -fsSLo /usr/local/bin/cloud-sql-proxy \
  https://storage.googleapis.com/cloud-sql-connectors/cloud-sql-proxy/v2.23.0/cloud-sql-proxy.linux.amd64
printf '%s  %s\n' cd689d582b826fa5bc82c01ccc14e45a58200c3cefbf923ce96c422825e4e6f6 \
  /usr/local/bin/cloud-sql-proxy | sha256sum -c -
chmod 0755 /usr/local/bin/cloud-sql-proxy
/usr/local/bin/cloud-sql-proxy --private-ip --auto-iam-authn --address 127.0.0.1 --port 5432 \
  '${connection_name}' >/var/log/cloud-sql-proxy.log 2>&1 &
for _ in \$(seq 1 60); do
  pg_isready -h 127.0.0.1 -p 5432 && break
  sleep 2
done
PGOPTIONS='-c role=emisar_owner' psql -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -U '${prefix}@${project}.iam' -d emisar \
  -c 'SELECT session_user, current_user, count(*) AS account_rows FROM accounts;'
PGOPTIONS='-c role=emisar_owner' psql -v ON_ERROR_STOP=1 \
  -h 127.0.0.1 -U '${prefix}@${project}.iam' -d emisar -c 'SELECT 1;'
echo EMISAR_DRILL_AUTH_OK

for _ in \$(seq 1 120); do
  ready=\$(curl -fsS -H 'Metadata-Flavor: Google' \
    http://metadata.google.internal/computeMetadata/v1/instance/attributes/revocation-ready || true)
  [[ \$ready == true ]] && break
  sleep 2
done
[[ \${ready:-} == true ]] || { echo 'revocation signal not received' >&2; exit 1; }

denied=0
for _ in \$(seq 1 60); do
  if PGOPTIONS='-c role=emisar_owner' psql -v ON_ERROR_STOP=1 \
    -h 127.0.0.1 -U '${prefix}@${project}.iam' -d emisar -c 'SELECT 1;'; then
    denied=0
  elif kill -0 \$! && pg_isready -h 127.0.0.1 -p 5432 >/dev/null; then
    denied=\$((denied + 1))
    if [[ \$denied -ge 3 ]]; then
      echo EMISAR_DRILL_REVOCATION_OK
      exit 0
    fi
  fi
  sleep 5
done
echo 'fresh IAM connections were not denied after revocation' >&2
exit 1
EOF

gcloud compute instances create "$vm" \
  --project "$project" \
  --zone "$zone" \
  --machine-type=e2-micro \
  --image-family=debian-13 \
  --image-project=debian-cloud \
  --network=emisar-vpc \
  --subnet=emisar-us-central1 \
  --no-address \
  --service-account="$service_account" \
  --scopes=cloud-platform \
  --metadata=serial-port-enable=true \
  --metadata-from-file=startup-script="$tmp/startup.sh" \
  --labels="purpose=recovery-drill,drill_id=${prefix},expires=${expires}"

auth_verified=false
for _ in $(seq 1 60); do
  serial=$(gcloud compute instances get-serial-port-output "$vm" \
    --project "$project" --zone "$zone" 2>&1 || true)
  if grep -q EMISAR_DRILL_AUTH_OK <<<"$serial"; then
    auth_verified=true
    break
  fi
  sleep 10
done

if [[ $auth_verified != true ]]; then
  echo "recovery authentication probe did not complete" >&2
  printf '%s\n' "$serial" >&2
  exit 1
fi

measured_rto_seconds=$(($(date +%s) - drill_start_epoch))
{
  printf 'restored_serving_at=%q\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  printf 'measured_rto_seconds=%q\n' "$measured_rto_seconds"
} >>"$manifest"
echo "restored clone served an emisar_owner query ${measured_rto_seconds}s ($((measured_rto_seconds / 60))m$((measured_rto_seconds % 60))s) after drill start"

gcloud sql users delete "${prefix}@${project}.iam" \
  --project "$project" --instance "$clone" --quiet
gcloud compute instances add-metadata "$vm" --project "$project" --zone "$zone" \
  --metadata=revocation-ready=true --quiet

for _ in $(seq 1 60); do
  serial=$(gcloud compute instances get-serial-port-output "$vm" \
    --project "$project" --zone "$zone" 2>&1 || true)
  if grep -q EMISAR_DRILL_REVOCATION_OK <<<"$serial"; then
    echo "PITR, reconnect, IAM owner role, and IAM revocation verified on scratch resources"
    exit 0
  fi
  sleep 10
done

echo "recovery revocation probe did not complete" >&2
printf '%s\n' "$serial" >&2
exit 1
