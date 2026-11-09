#!/bin/sh
set -eu
project=$1 region=$2 size=$3 cluster=$4 state=$5 start_time=$6 end_time=$7
/bin/bash /packs/gcp-dataproc/scripts/dataproc.sh jobs_list "$project" "$region" "$size" '' "$cluster" "$state" "$start_time" "$end_time" | jq -er .next_page_cursor
