#!/bin/sh
set -eu
mode=$1
shift
cursor=$(/bin/sh /packs/gcp-monitoring/test/fixtures/first-page.sh "$@")
remaining=${cursor#v1.}
anchor=${remaining%%.*}
remaining=${remaining#*.}
fingerprint=${remaining%%.*}
provider=${remaining#*.}
case "$mode" in
  future) anchor=9999999999 ;;
  overflow) anchor=99999999999 ;;
  negative) anchor=-1 ;;
  leading-zero) anchor=01700000000 ;;
  empty-provider) provider='' ;;
  long-provider) provider=$(jq -nr '"C" * 1025') ;;
  *) exit 2 ;;
esac
printf 'v1.%s.%s.%s\n' "$anchor" "$fingerprint" "$provider"
