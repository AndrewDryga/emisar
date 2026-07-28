#!/bin/sh
set -eu

mode=$1
project=$2

project_with_jq() {
  filter=$1
  shift
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  "$@" >"$tmp"
  jq -e "$filter" "$tmp"
}

bucket_projection='
  {
    name,
    location,
    locationType: .location_type,
    storageClass: .default_storage_class,
    rpo,
    uniformBucketLevelAccess: .uniform_bucket_level_access,
    publicAccessPrevention: .public_access_prevention,
    versioningEnabled: .versioning_enabled,
    retentionPolicy: (
      if .retention_policy then {
        retentionPeriod: .retention_policy.retentionPeriod,
        isLocked: .retention_policy.isLocked,
        effectiveTime: .retention_policy.effectiveTime
      } else null end
    ),
    softDeletePolicy: .soft_delete_policy,
    lifecycle: {
      rule: [
        (.lifecycle_config.rule // [])[] | {
          action: {
            type: .action.type,
            storageClass: .action.storageClass
          },
          condition
        }
      ]
    },
    defaultKmsKeyName: .default_kms_key,
    autoclass,
    hierarchicalNamespace: .hierarchical_namespace,
    ipFilter: .ip_filter
  }
'

object_projection='
  {
    name,
    bucket,
    size,
    contentType: .content_type,
    storageClass: .storage_class,
    generation,
    metageneration,
    timeCreated: .creation_time,
    updated: .update_time,
    timeStorageClassUpdated: .storage_class_update_time,
    timeDeleted: .deletion_time,
    softDeleteTime: .soft_delete_time,
    hardDeleteTime: .hard_delete_time,
    md5Hash: .md5_hash,
    crc32c: .crc32c_hash,
    etag,
    kmsKeyName: .kms_key,
    temporaryHold: .temporary_hold,
    eventBasedHold: .event_based_hold,
    retention,
    metadataKeys: ((.custom_fields // {}) | keys),
    contextKeys: ((.contexts // {}) | keys)
  }
'

case "$mode" in
  buckets)
    project_with_jq "map($bucket_projection)" \
      gcloud storage buckets list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  bucket-describe)
    project_with_jq "$bucket_projection" \
      gcloud storage buckets describe "gs://$3" \
      "--project=$project" --format=json --quiet
    ;;
  bucket-policy)
    project_with_jq \
      '{
        version,
        etag,
        bindings: [(.bindings // [])[] | {role, members, condition}]
      }' \
      gcloud storage buckets get-iam-policy "gs://$3" \
      "--project=$project" --format=json --quiet
    ;;
  objects)
    url="gs://$3/$4**"
    project_with_jq "map($object_projection)" \
      gcloud storage objects list "$url" \
      "--project=$project" "--limit=$5" --format=json --quiet
    ;;
  object-describe)
    project_with_jq "$object_projection" \
      gcloud storage objects describe "gs://$3/$4" \
      "--project=$project" --format=json --quiet
    ;;
  *)
    echo "unsupported Cloud Storage operation" >&2
    exit 2
    ;;
esac
