#!/bin/sh
set -eu

mode=$1
project=$2

scope_flag() {
  case "$1" in
    global)
      [ -z "$2" ] || {
        echo "location must be empty for global scope" >&2
        exit 2
      }
      printf '%s\n' --global
      ;;
    region)
      [ -n "$2" ] || {
        echo "location is required for region scope" >&2
        exit 2
      }
      printf '%s\n' "--region=$2"
      ;;
    *)
      echo "scope must be global or region" >&2
      exit 2
      ;;
  esac
}

project_with_jq() {
  filter=$1
  shift
  umask 077
  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT HUP INT TERM
  "$@" >"$tmp"
  jq -e "$filter" "$tmp"
}

legacy_certificate='
  {
    name,
    region,
    type,
    certificateSource: (
      if .managed then "MANAGED"
      elif .certificate then "SELF_MANAGED"
      else "UNKNOWN"
      end
    ),
    managedDomains: (.managed.domains // []),
    managedStatus: (.managed.status // null),
    subjectAlternativeNames,
    expireTime
  }
'

managed_certificate='
  {
    name,
    scope,
    sanDnsnames,
    source: (
      if .managed then "MANAGED"
      elif .selfManaged then "SELF_MANAGED"
      else "UNKNOWN"
      end
    ),
    managed: (
      if .managed then {
        domains: .managed.domains,
        state: .managed.state,
        authorizationAttemptInfo: [
          (.managed.authorizationAttemptInfo // [])[] |
          {domain, state, failureReason}
        ],
        provisioningIssue: (
          if .managed.provisioningIssue then {
            reason: .managed.provisioningIssue.reason
          } else null end
        )
      } else null end
    ),
    createTime,
    updateTime,
    expireTime
  }
'

case "$mode" in
  ssl-certificates)
    project_with_jq "map($legacy_certificate)" \
      gcloud compute ssl-certificates list \
      "--project=$project" "--limit=$3" --format=json --quiet
    ;;
  ssl-certificate-describe)
    flag=$(scope_flag "$4" "$5")
    project_with_jq "$legacy_certificate" \
      gcloud compute ssl-certificates describe "$3" "$flag" \
      "--project=$project" --format=json --quiet
    ;;
  managed-certificates)
    project_with_jq "map($managed_certificate)" \
      gcloud certificate-manager certificates list \
      "--project=$project" "--location=$3" "--limit=$4" --format=json --quiet
    ;;
  managed-certificate-describe)
    project_with_jq "$managed_certificate" \
      gcloud certificate-manager certificates describe "$3" \
      "--project=$project" "--location=$4" --format=json --quiet
    ;;
  certificate-maps)
    project_with_jq \
      'map({name, gclbTargets, createTime, updateTime})' \
      gcloud certificate-manager maps list \
      "--project=$project" "--location=$3" "--limit=$4" --format=json --quiet
    ;;
  certificate-map-entries)
    project_with_jq \
      'map({name, hostname, matcher, certificates, state, createTime, updateTime})' \
      gcloud certificate-manager maps entries list \
      "--map=$3" "--project=$project" "--location=$4" "--limit=$5" --format=json --quiet
    ;;
  dns-authorizations)
    project_with_jq \
      'map({name, domain, type, dnsResourceRecord, createTime, updateTime})' \
      gcloud certificate-manager dns-authorizations list \
      "--project=$project" "--location=$3" "--limit=$4" --format=json --quiet
    ;;
  *)
    echo "unsupported certificate operation" >&2
    exit 2
    ;;
esac
