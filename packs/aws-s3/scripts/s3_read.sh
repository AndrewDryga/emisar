#!/bin/sh
set -eu

project_with_jq() {
  filter=$1
  shift
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  "$@" >"$tmp"
  jq -e "$filter" "$tmp"
}

case "$1" in
  buckets)
    limit=$2
    token=$3
    set -- aws s3api list-buckets --max-buckets "$limit" --no-paginate --output json
    [ -z "$token" ] || set -- "$@" --continuation-token "$token"
    project_with_jq \
      '{
        Buckets: [(.Buckets // [])[] | {
          Name,
          CreationDate,
          BucketArn,
          BucketRegion
        }],
        Prefix,
        ContinuationToken
      }' \
      "$@"
    ;;
  objects)
    bucket=$2
    prefix=$3
    limit=$4
    token=$5
    set -- aws s3api list-objects-v2 \
      --bucket "$bucket" --prefix "$prefix" --max-keys "$limit" --no-paginate --output json
    [ -z "$token" ] || set -- "$@" --continuation-token "$token"
    project_with_jq \
      '{
        Name,
        Prefix,
        KeyCount,
        MaxKeys,
        IsTruncated,
        NextContinuationToken,
        Contents: [(.Contents // [])[] | {
          Key,
          LastModified,
          ETag,
          ChecksumAlgorithm,
          ChecksumType,
          Size,
          StorageClass
        }]
      }' \
      "$@"
    ;;
  object)
    project_with_jq \
      '{
        DeleteMarker,
        AcceptRanges,
        Expiration,
        Restore,
        ArchiveStatus,
        LastModified,
        ContentLength,
        ChecksumCRC32,
        ChecksumCRC32C,
        ChecksumCRC64NVME,
        ChecksumSHA1,
        ChecksumSHA256,
        ChecksumType,
        ETag,
        MissingMeta,
        VersionId,
        CacheControl,
        ContentDisposition,
        ContentEncoding,
        ContentLanguage,
        ContentType,
        Expires,
        WebsiteRedirectLocation,
        ServerSideEncryption,
        SSECustomerAlgorithm,
        SSEKMSKeyId,
        BucketKeyEnabled,
        StorageClass,
        RequestCharged,
        ReplicationStatus,
        PartsCount,
        ObjectLockMode,
        ObjectLockRetainUntilDate,
        ObjectLockLegalHoldStatus,
        MetadataKeys: ((.Metadata // {}) | keys)
      }' \
      aws s3api head-object --bucket "$2" --key "$3" --no-paginate --output json
    ;;
  *)
    echo "unsupported S3 read operation" >&2
    exit 2
    ;;
esac
