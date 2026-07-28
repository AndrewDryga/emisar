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

page() {
  filter=$1
  limit=$2
  token=$3
  shift 3
  set -- aws rds "$@" --page-size "$limit" --max-items "$limit" --output json
  [ -z "$token" ] || set -- "$@" --starting-token "$token"
  project_with_jq "$filter" "$@"
}

instance_projection='
  {
    DBInstanceIdentifier,
    DBInstanceClass,
    Engine,
    EngineVersion,
    DBInstanceStatus,
    AvailabilityZone,
    SecondaryAvailabilityZone,
    MultiAZ,
    PubliclyAccessible,
    StorageType,
    AllocatedStorage,
    MaxAllocatedStorage,
    StorageEncrypted,
    KmsKeyId,
    Iops,
    StorageThroughput,
    BackupRetentionPeriod,
    PreferredBackupWindow,
    PreferredMaintenanceWindow,
    AutoMinorVersionUpgrade,
    DeletionProtection,
    CopyTagsToSnapshot,
    PerformanceInsightsEnabled,
    MonitoringInterval,
    IAMDatabaseAuthenticationEnabled,
    CustomerOwnedIpEnabled,
    NetworkType,
    ActivityStreamStatus,
    CertificateDetails,
    Endpoint,
    DBSubnetGroup: (
      if .DBSubnetGroup then {
        DBSubnetGroupName: .DBSubnetGroup.DBSubnetGroupName,
        VpcId: .DBSubnetGroup.VpcId,
        SubnetGroupStatus: .DBSubnetGroup.SubnetGroupStatus,
        Subnets: [(.DBSubnetGroup.Subnets // [])[] | {
          SubnetIdentifier,
          SubnetAvailabilityZone,
          SubnetOutpost,
          SubnetStatus
        }]
      } else null end
    ),
    VpcSecurityGroups: [(.VpcSecurityGroups // [])[] | {
      VpcSecurityGroupId,
      Status
    }],
    DBParameterGroups: [(.DBParameterGroups // [])[] | {
      DBParameterGroupName,
      ParameterApplyStatus
    }],
    OptionGroupMemberships: [(.OptionGroupMemberships // [])[] | {
      OptionGroupName,
      Status
    }],
    PendingModifiedValueKeys: ((.PendingModifiedValues // {}) | keys)
  }
'

cluster_projection='
  {
    DBClusterIdentifier,
    Engine,
    EngineMode,
    EngineVersion,
    Status,
    AvailabilityZones,
    MultiAZ,
    Endpoint,
    ReaderEndpoint,
    CustomEndpoints,
    Port,
    DBClusterArn,
    DBClusterResourceId,
    DatabaseName,
    DBSubnetGroup,
    VpcSecurityGroups: [(.VpcSecurityGroups // [])[] | {
      VpcSecurityGroupId,
      Status
    }],
    DBClusterMembers: [(.DBClusterMembers // [])[] | {
      DBInstanceIdentifier,
      IsClusterWriter,
      DBClusterParameterGroupStatus,
      PromotionTier
    }],
    BackupRetentionPeriod,
    PreferredBackupWindow,
    PreferredMaintenanceWindow,
    StorageEncrypted,
    KmsKeyId,
    IAMDatabaseAuthenticationEnabled,
    DeletionProtection,
    CopyTagsToSnapshot,
    AutoMinorVersionUpgrade,
    NetworkType,
    ServerlessV2ScalingConfiguration,
    ScalingConfigurationInfo,
    GlobalWriteForwardingStatus,
    LocalWriteForwardingStatus,
    ActivityStreamStatus,
    CertificateDetails,
    PendingModifiedValueKeys: ((.PendingModifiedValues // {}) | keys)
  }
'

snapshot_projection='
  {
    DBSnapshotIdentifier,
    DBInstanceIdentifier,
    SnapshotCreateTime,
    Engine,
    EngineVersion,
    Status,
    AllocatedStorage,
    AvailabilityZone,
    Port,
    VpcId,
    InstanceCreateTime,
    MasterUsername,
    SnapshotType,
    PercentProgress,
    Encrypted,
    KmsKeyId,
    StorageType,
    Iops,
    StorageThroughput,
    SourceRegion,
    SourceDBSnapshotIdentifier,
    SnapshotTarget,
    DedicatedLogVolume
  }
'

cluster_snapshot_projection='
  {
    DBClusterSnapshotIdentifier,
    DBClusterIdentifier,
    SnapshotCreateTime,
    Engine,
    EngineMode,
    EngineVersion,
    Status,
    AllocatedStorage,
    AvailabilityZones,
    Port,
    VpcId,
    ClusterCreateTime,
    MasterUsername,
    SnapshotType,
    PercentProgress,
    Encrypted,
    KmsKeyId,
    StorageType,
    SourceRegion,
    SourceDBClusterSnapshotIdentifier,
    DBSystemId
  }
'

case "$1" in
  instances)
    page \
      "{DBInstances: [(.DBInstances // [])[] | $instance_projection], NextToken}" \
      "$2" "$3" describe-db-instances
    ;;
  instance)
    project_with_jq \
      "{DBInstances: [(.DBInstances // [])[] | $instance_projection]}" \
      aws rds describe-db-instances --db-instance-identifier "$2" --no-paginate --output json
    ;;
  clusters)
    page \
      "{DBClusters: [(.DBClusters // [])[] | $cluster_projection], NextToken}" \
      "$2" "$3" describe-db-clusters
    ;;
  cluster)
    project_with_jq \
      "{DBClusters: [(.DBClusters // [])[] | $cluster_projection]}" \
      aws rds describe-db-clusters --db-cluster-identifier "$2" --no-paginate --output json
    ;;
  snapshots)
    page \
      "{DBSnapshots: [(.DBSnapshots // [])[] | $snapshot_projection], NextToken}" \
      "$2" "$3" describe-db-snapshots
    ;;
  cluster-snapshots)
    page \
      "{DBClusterSnapshots: [(.DBClusterSnapshots // [])[] | $cluster_snapshot_projection], NextToken}" \
      "$2" "$3" describe-db-cluster-snapshots
    ;;
  parameter-groups)
    page \
      '{
        DBParameterGroups: [(.DBParameterGroups // [])[] | {
          DBParameterGroupName,
          DBParameterGroupFamily,
          DBParameterGroupArn
        }],
        NextToken
      }' \
      "$2" "$3" describe-db-parameter-groups
    ;;
  cluster-parameter-groups)
    page \
      '{
        DBClusterParameterGroups: [(.DBClusterParameterGroups // [])[] | {
          DBClusterParameterGroupName,
          DBParameterGroupFamily,
          DBClusterParameterGroupArn
        }],
        NextToken
      }' \
      "$2" "$3" describe-db-cluster-parameter-groups
    ;;
  pending-maintenance)
    page \
      '{
        PendingMaintenanceActions: [(.PendingMaintenanceActions // [])[] | {
          ResourceIdentifier,
          PendingMaintenanceActionDetails: [
            (.PendingMaintenanceActionDetails // [])[] | {
              Action,
              AutoAppliedAfterDate,
              ForcedApplyDate,
              OptInStatus,
              CurrentApplyDate,
              Description
            }
          ]
        }],
        NextToken
      }' \
      "$2" "$3" describe-pending-maintenance-actions
    ;;
  events)
    page \
      '{
        Events: [(.Events // [])[] | {
          SourceIdentifier,
          SourceType,
          Message,
          EventCategories,
          Date,
          SourceArn
        }],
        NextToken
      }' \
      "$3" "$4" describe-events --duration "$2"
    ;;
  *)
    echo "unsupported RDS read operation" >&2
    exit 2
    ;;
esac
