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

instance_projection='
  {
    name,
    project,
    region,
    gceZone,
    secondaryGceZone,
    databaseVersion,
    state,
    instanceType,
    connectionName,
    ipAddresses,
    ipv6Address,
    dnsName,
    primaryDnsName,
    writeEndpoint,
    pscServiceAttachmentLink,
    serverCaMode,
    serverCaPool,
    satisfiesPzi,
    masterInstanceName,
    replicaNames,
    failoverReplica: (
      if .failoverReplica then {
        name: .failoverReplica.name,
        available: .failoverReplica.available
      } else null end
    ),
    settings: {
      tier: .settings.tier,
      edition: .settings.edition,
      availabilityType: .settings.availabilityType,
      activationPolicy: .settings.activationPolicy,
      diskType: .settings.dataDiskType,
      diskSizeGb: .settings.dataDiskSizeGb,
      diskAutoresize: .settings.storageAutoResize,
      diskAutoresizeLimit: .settings.storageAutoResizeLimit,
      deletionProtectionEnabled: .settings.deletionProtectionEnabled,
      backupConfiguration: (
        if .settings.backupConfiguration then {
          enabled: .settings.backupConfiguration.enabled,
          location: .settings.backupConfiguration.location,
          pointInTimeRecoveryEnabled: .settings.backupConfiguration.pointInTimeRecoveryEnabled,
          transactionLogRetentionDays: .settings.backupConfiguration.transactionLogRetentionDays,
          retainedBackups: .settings.backupConfiguration.backupRetentionSettings.retainedBackups,
          retentionUnit: .settings.backupConfiguration.backupRetentionSettings.retentionUnit,
          startTime: .settings.backupConfiguration.startTime
        } else null end
      ),
      ipConfiguration: (
        if .settings.ipConfiguration then {
          ipv4Enabled: .settings.ipConfiguration.ipv4Enabled,
          privateNetwork: .settings.ipConfiguration.privateNetwork,
          requireSsl: .settings.ipConfiguration.requireSsl,
          sslMode: .settings.ipConfiguration.sslMode,
          allocatedIpRange: .settings.ipConfiguration.allocatedIpRange,
          pscEnabled: .settings.ipConfiguration.pscConfig.pscEnabled,
          authorizedNetworks: [
            (.settings.ipConfiguration.authorizedNetworks // [])[] |
            {value, expirationTime}
          ]
        } else null end
      ),
      maintenanceWindow: .settings.maintenanceWindow,
      insightsConfig: .settings.insightsConfig,
      databaseFlagNames: [(.settings.databaseFlags // [])[] | .name]
    }
  }
'

operation_projection='
  {
    name,
    operationType,
    status,
    targetId,
    targetProject,
    targetLink,
    user,
    insertTime,
    startTime,
    endTime,
    errorCodes: [(.error.errors // [])[] | .code],
    apiWarningCode: .apiWarning.code
  }
'

case "$mode" in
  instances)
    project_with_jq "map($instance_projection)" \
      gcloud sql instances list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  instance-describe)
    project_with_jq "$instance_projection" \
      gcloud sql instances describe "$3" \
      "--project=$project" --format=json --quiet
    ;;
  databases)
    project_with_jq \
      'map({name, instance, project, charset, collation, sqlserverDatabaseDetails})' \
      gcloud sql databases list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  users)
    project_with_jq \
      'map({name, host, instance, project, type, passwordPolicy})' \
      gcloud sql users list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  backups)
    project_with_jq \
      'map({
        id,
        instance,
        project,
        status,
        type,
        backupKind,
        databaseVersion,
        location,
        windowStartTime,
        startTime,
        endTime,
        enqueuedTime
      })' \
      gcloud sql backups list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  operations)
    project_with_jq "map($operation_projection)" \
      gcloud sql operations list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  operation-describe)
    project_with_jq "$operation_projection" \
      gcloud sql operations describe "$3" \
      "--project=$project" --format=json --quiet
    ;;
  server-ca-certs)
    project_with_jq \
      'map({
        certSerialNumber,
        commonName,
        createTime,
        expirationTime,
        instance,
        sha1Fingerprint,
        type
      })' \
      gcloud sql ssl server-ca-certs list \
      "--instance=$3" "--project=$project" "--limit=$4" --format=json --quiet
    ;;
  *)
    echo "unsupported Cloud SQL operation" >&2
    exit 2
    ;;
esac
