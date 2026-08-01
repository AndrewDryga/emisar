#!/bin/sh
set -eu

mode=$1
name=$2
scope=$3
location=$4
project=$5
size=${6-}

case "$scope" in
  global)
    if [ -n "$location" ]; then
      printf '%s\n' "location must be empty when scope is global" >&2
      exit 2
    fi
    set -- --global
    ;;
  region|zone)
    if [ -z "$location" ]; then
      printf '%s\n' "location is required when scope is $scope" >&2
      exit 2
    fi
    set -- "--${scope}=${location}"
    ;;
  *)
    printf '%s\n' "unsupported scope: $scope" >&2
    exit 2
    ;;
esac

case "$mode" in
  mig-instances)
    [ "$scope" != global ] || {
      printf '%s\n' "managed instance groups must be zonal or regional" >&2
      exit 2
    }
    exec gcloud compute instance-groups managed list-instances "$name" "$@" \
      "--project=$project" --limit=500 --format=json --quiet
    ;;
  mig-health)
    [ "$scope" != global ] || {
      printf '%s\n' "managed instance groups must be zonal or regional" >&2
      exit 2
    }
    exec gcloud compute instance-groups managed describe "$name" "$@" \
      "--project=$project" \
      "--format=json(name,targetSize,status,versions,autoHealingPolicies,updatePolicy,instanceGroup)" \
      --quiet
    ;;
  mig-resize)
    [ "$scope" != global ] || {
      printf '%s\n' "managed instance groups must be zonal or regional" >&2
      exit 2
    }
    [ -n "$size" ] || {
      printf '%s\n' "size is required" >&2
      exit 2
    }
    exec gcloud compute instance-groups managed resize "$name" "$@" \
      "--project=$project" "--size=$size" \
      "--format=json(name,targetSize,status,versions,autoHealingPolicies,updatePolicy,instanceGroup)" \
      --quiet
    ;;
  backend-health)
    [ "$scope" != zone ] || {
      printf '%s\n' "backend services must be global or regional" >&2
      exit 2
    }
    exec gcloud compute backend-services get-health "$name" "$@" \
      "--project=$project" --limit=500 --format=json --quiet
    ;;
  operation-status)
    exec gcloud compute operations describe "$name" "$@" \
      "--project=$project" \
      "--format=json(name,status,operationType,progress,insertTime,startTime,endTime,targetLink,zone,region,error,warnings,httpErrorStatusCode,httpErrorMessage)" \
      --quiet
    ;;
  *)
    printf '%s\n' "unsupported compute operation: $mode" >&2
    exit 2
    ;;
esac
